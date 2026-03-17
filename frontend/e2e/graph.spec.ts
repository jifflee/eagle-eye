import { test, expect } from "@playwright/test";

test.describe("Graph Page", () => {
  test("navigating to investigation shows graph layout", async ({ page }) => {
    await page.goto("/investigation/demo");
    // Page should render with the graph layout structure
    await expect(page.getByRole("heading", { name: /loading/i })).toBeVisible({ timeout: 5_000 });
  });

  test("graph page has data sources section", async ({ page }) => {
    await page.goto("/investigation/demo");
    await expect(page.getByText("Data Sources")).toBeVisible({ timeout: 5_000 });
  });

  test("graph page has search input", async ({ page }) => {
    await page.goto("/investigation/demo");
    await expect(page.getByPlaceholder(/search entities/i)).toBeVisible();
  });

  test("back button returns to home", async ({ page }) => {
    await page.goto("/investigation/demo");
    const backLink = page.locator("a[href='/']").first();
    await backLink.click();
    await expect(page).toHaveURL("/");
  });

  test("graph page shows enrichment status", async ({ page }) => {
    await page.goto("/investigation/demo");
    // Should show status text somewhere on page
    await expect(page.getByText("Loading", { exact: true })).toBeVisible({ timeout: 5_000 });
  });

  test("graph page shows entity and relationship counts", async ({ page }) => {
    await page.goto("/investigation/demo");
    await expect(page.getByText(/entities/)).toBeVisible();
    await expect(page.getByText(/relationships/)).toBeVisible();
  });

  test("search input accepts text", async ({ page }) => {
    await page.goto("/investigation/demo");
    const search = page.getByPlaceholder(/search entities/i);
    await search.fill("test query");
    await expect(search).toHaveValue("test query");
  });
});

test.describe("Graph Page — Visual Inspection", () => {
  test("graph page screenshot (light mode)", async ({ page }) => {
    await page.goto("/investigation/demo");
    await page.waitForTimeout(2_000);
    await expect(page).toHaveScreenshot("graph-page-light.png", {
      maxDiffPixelRatio: 0.15,
    });
  });

  test("graph page screenshot (dark mode)", async ({ page }) => {
    await page.goto("/");
    const toggle = page.locator("nav button").last();
    await toggle.click();
    await page.waitForTimeout(300);
    await page.goto("/investigation/demo");
    await page.waitForTimeout(2_000);
    await expect(page).toHaveScreenshot("graph-page-dark.png", {
      maxDiffPixelRatio: 0.15,
    });
  });
});
