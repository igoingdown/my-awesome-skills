import fetch from 'node-fetch';

// --- Configuration ---

const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY;
const FEISHU_APP_ID = process.env.FEISHU_APP_ID;
const FEISHU_APP_SECRET = process.env.FEISHU_APP_SECRET;
const FEISHU_RECEIVER_OPEN_ID = process.env.FEISHU_RECEIVER_OPEN_ID;

const OPENROUTER_BALANCE_URL = 'https://openrouter.ai/api/v1/credits';
const FEISHU_TOKEN_URL = 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal';
const FEISHU_SEND_URL = 'https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id';

const MAX_RETRIES = 2;
const RETRY_BASE_DELAY_MS = 1000;

// --- Types ---

interface OpenRouterBalanceResponse {
  data: {
    total_credits: number;
    total_usage: number;
  };
}

interface TenantAccessTokenResponse {
  code?: number;
  msg?: string;
  tenant_access_token?: string;
}

interface FeishuSendResponse {
  code?: number;
  msg?: string;
}

// --- Helpers ---

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function formatAmount(value: number): string {
  return `$${value.toFixed(2)}`;
}

function buildCardMessage(
  totalCredits: number,
  totalUsage: number,
  remaining: number,
): string {
  return JSON.stringify({
    config: { wide_screen_mode: true },
    header: {
      title: { tag: 'plain_text', content: 'OpenRouter 账户报告' },
      template: 'blue',
    },
    elements: [
      {
        tag: 'div',
        text: {
          tag: 'lark_md',
          content: `**总额度**: ${formatAmount(totalCredits)}\n**已使用**: ${formatAmount(totalUsage)}\n**剩余额度**: ${formatAmount(remaining)}`,
        },
      },
    ],
  });
}

function buildErrorMessage(errorSummary: string): string {
  return JSON.stringify({
    config: { wide_screen_mode: true },
    header: {
      title: { tag: 'plain_text', content: 'OpenRouter 查询异常' },
      template: 'red',
    },
    elements: [
      {
        tag: 'div',
        text: {
          tag: 'lark_md',
          content: `查询 OpenRouter 余额失败：\n${errorSummary}`,
        },
      },
    ],
  });
}

// --- Core Logic ---

async function getTenantAccessToken(): Promise<string> {
  if (!FEISHU_APP_ID || !FEISHU_APP_SECRET) {
    throw new Error('FEISHU_APP_ID or FEISHU_APP_SECRET is not set');
  }

  const response = await fetch(FEISHU_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      app_id: FEISHU_APP_ID,
      app_secret: FEISHU_APP_SECRET,
    }),
  });

  if (!response.ok) {
    throw new Error(
      `Failed to get tenant_access_token: HTTP ${response.status}`,
    );
  }

  const data = (await response.json()) as TenantAccessTokenResponse;

  if (!data.tenant_access_token) {
    throw new Error(
      `No tenant_access_token returned: code=${data.code}, msg=${data.msg}`,
    );
  }

  return data.tenant_access_token;
}

async function queryOpenRouterBalance(
  apiKey: string,
): Promise<OpenRouterBalanceResponse> {
  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) {
      const delay = RETRY_BASE_DELAY_MS * Math.pow(2, attempt - 1);
      console.warn(
        `Retry ${attempt}/${MAX_RETRIES} in ${delay}ms (last error: ${lastError?.message})`,
      );
      await sleep(delay);
    }

    try {
      const response = await fetch(OPENROUTER_BALANCE_URL, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
      });

      if (!response.ok) {
        throw new Error(`OpenRouter API error: HTTP ${response.status}`);
      }

      const data = (await response.json()) as OpenRouterBalanceResponse;

      if (
        data.data == null ||
        typeof data.data.total_credits !== 'number' ||
        typeof data.data.total_usage !== 'number'
      ) {
        throw new Error('Unexpected response shape from OpenRouter API');
      }

      return data;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      console.warn(`Attempt ${attempt + 1} failed: ${lastError.message}`);
    }
  }

  throw new Error(
    `OpenRouter API failed after ${MAX_RETRIES + 1} attempts: ${lastError?.message}`,
  );
}

async function sendFeishuMessage(
  token: string,
  content: string,
): Promise<void> {
  if (!FEISHU_RECEIVER_OPEN_ID) {
    throw new Error('FEISHU_RECEIVER_OPEN_ID is not set');
  }

  const response = await fetch(FEISHU_SEND_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      receive_id: FEISHU_RECEIVER_OPEN_ID,
      msg_type: 'interactive',
      content,
    }),
  });

  if (!response.ok) {
    throw new Error(`Failed to send Feishu message: HTTP ${response.status}`);
  }

  const data = (await response.json()) as FeishuSendResponse;

  if (data.code !== 0) {
    throw new Error(`Feishu API error: code=${data.code}, msg=${data.msg}`);
  }
}

// --- Main ---

async function main(): Promise<void> {
  if (!OPENROUTER_API_KEY) {
    console.error('Error: OPENROUTER_API_KEY is not set');
    process.exit(1);
  }

  try {
    // Step 1: Get tenant_access_token from Feishu
    console.log('Getting Feishu tenant_access_token...');
    const token = await getTenantAccessToken();

    // Step 2: Query OpenRouter balance with retries
    console.log('Querying OpenRouter balance...');
    const balance = await queryOpenRouterBalance(OPENROUTER_API_KEY);

    const totalCredits = balance.data.total_credits;
    const totalUsage = balance.data.total_usage;
    const remaining = totalCredits - totalUsage;

    console.log(
      `Balance: total=${formatAmount(totalCredits)}, used=${formatAmount(totalUsage)}, remaining=${formatAmount(remaining)}`,
    );

    // Step 3: Send interactive card to Feishu
    console.log('Sending card message to Feishu...');
    const cardMessage = buildCardMessage(totalCredits, totalUsage, remaining);
    await sendFeishuMessage(token, cardMessage);
    console.log('Done! Card sent successfully.');
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : String(error);
    console.error(`Fatal error: ${errorMessage}`);

    // Attempt to send error notification to Feishu
    try {
      const token = await getTenantAccessToken();
      const errorCard = buildErrorMessage(errorMessage);
      await sendFeishuMessage(token, errorCard);
      console.log('Error notification sent to Feishu.');
    } catch (feishuError) {
      const feishuErrorMsg =
        feishuError instanceof Error ? feishuError.message : String(feishuError);
      console.error(`Failed to send error notification: ${feishuErrorMsg}`);
    }

    process.exit(1);
  }
}

main();
