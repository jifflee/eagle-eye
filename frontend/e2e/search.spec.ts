import { test, expect } from "@playwright/test";

test.describe("Search Page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/search");
  });

  test("renders search page with input and button", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /search/i })).toBeVisible();
    await expect(page.getByPlaceholder(/search people/i)).toBeVisible();
    await expect(page.getByRole("button", { name: /search/i })).toBeVisible();
  });

  test("submitting search shows results or empty state", async ({ page }) => {
    await page.getByPlaceholder(/search people/i).fill("John");
    await page.getByRole("button", { name: /search/i }).click();

    // Should show results count (even if 0)
    await expect(page.getByText(/result/i)).toBeVisible({ timeout: 5_000 });
  });

  test("empty search does nothing", async ({ page }) => {
    await page.getByRole("button", { name: /search/i }).click();
    // Should not show results section
    await expect(page.getByText(/0 result/i)).not.toBeVisible();
  });
});
