type ReadResponse = {
  status: number;
  error: { code?: string; message?: string } | null;
};

const networkFailure = /failed to fetch|fetch failed|network(?: request|error| error)|load failed|connection (?:reset|closed)|timed? ?out/i;

/** Only wrap read queries. Rebuild the query for each of at most three attempts. */
export async function readWithRetry<T extends ReadResponse>(read: () => PromiseLike<T>): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      const result = await read();
      const transient = result.error && (
        [408, 429, 502, 503, 504].includes(result.status) ||
        (result.status === 0 && !result.error.code && networkFailure.test(result.error.message ?? ""))
      );
      if (!transient || attempt === 2) return result;
    } catch (error) {
      if (attempt === 2 || !(error instanceof TypeError) || !networkFailure.test(error.message)) throw error;
    }
    await new Promise<void>(resolve => setTimeout(resolve, attempt === 0 ? 250 : 750));
  }
}
