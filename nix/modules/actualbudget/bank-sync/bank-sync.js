// Runs the bank sync of Actual Budget for every linked account, as its UI does, and uploads what it imported. The
// server holds the bank credentials and talks to the providers (SimpleFIN, GoCardless, ...); this only talks to it.
// Lines start with their level, as the format actual-client of the logs reads them
const api = require('@actual-app/api');

function env(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing environment variable ${name}`);
  }
  return value;
}

// getAccounts() leaves out the sync fields
async function linkedAccounts() {
  const { data } = await api.aqlQuery(
    api
      .q('accounts')
      .filter({ account_sync_source: { $ne: null }, closed: false })
      .select(['name', 'account_sync_source', 'last_sync']),
  );
  return data;
}

function describe(accounts) {
  return accounts
    .map(({ name, account_sync_source, last_sync }) => {
      // Milliseconds since the epoch, as a string
      const date = new Date(Number(last_sync));
      const synced = !last_sync ? 'never' : isNaN(date) ? last_sync : date.toISOString();
      return `${name} (${account_sync_source}, last sync ${synced})`;
    })
    .join(', ');
}

async function main() {
  const syncId = env('ACTUAL_BUDGET_SYNC_ID');
  await api.init({
    serverURL: env('ACTUAL_BUDGET_URL').replace(/\/$/, ''),
    password: env('ACTUAL_BUDGET_PASS'),
    dataDir: env('ACTUAL_BUDGET_DATA_DIR'),
  });
  try {
    await api.downloadBudget(syncId);
    const before = await linkedAccounts();
    if (before.length === 0) {
      throw new Error('No open account is linked to a bank');
    }
    console.log(`info: Syncing ${before.length} linked accounts: ${describe(before)}`);
    // Without an accountId, Actual syncs every linked account, SimpleFIN accounts in one request. It throws the first
    // error after syncing the rest, so upload what it imported before failing
    let result, bankSyncError;
    try {
      result = await api.runBankSync();
    } catch (error) {
      bankSyncError = error;
    }
    await api.sync();
    if (bankSyncError) {
      throw bankSyncError;
    }
    console.log(
      `info: Bank sync done: ${result.newTransactions.length} new, ${result.matchedTransactions.length} matched ` +
        `transactions, ${result.updatedAccounts.length} accounts updated; ${describe(await linkedAccounts())}`,
    );
  } finally {
    await api.shutdown();
  }
}

main().catch((error) => {
  console.error(`error: Bank sync failed: ${error.message}${error.code ? ` (${error.code})` : ''}`);
  process.exitCode = 1;
});
