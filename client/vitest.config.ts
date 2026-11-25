import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // The end-to-end tests share one database, so test files run one after another.
    fileParallelism: false,
    testTimeout: 30_000,
  },
})
