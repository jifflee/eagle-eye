import { test, expect } from "@playwright/test";

test.describe("Home Page — Address Input Form", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
  });

  test("renders the Eagle Eye heading and form", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /eagle eye/i })).toBeVisible();
    await expect(page.getByPlaceholder("123 Main Street")).toBeVisible();
    await expect(page.getByPlaceholder("Lawrenceville")).toBeVisible();
    await expect(page.getByPlaceholder("GA")).toBeVisible();
    await expect(page.getByPlaceholder("30043")).toBeVisible();
    await expect(page.getByRole("button", { name: /investigate/i })).toBeVisible();
  });

  test("shows validation errors for empty fields", async ({ page }) => {
    // Clear the state field (pre-filled with GA)
    await page.getByPlaceholder("GA").clear();
    await page.getByRole("button", { name: /investigate/i }).click();

    await expect(page.getByText("Street address is required")).toBeVisible();
    await expect(page.getByText("City is required")).toBeVisible();
    await expect(page.getByText("State is required")).toBeVisible();
    await expect(page.getByText("ZIP code is required")).toBeVisible();
  });

  test("shows error for street without number", async ({ page }) => {
    await page.getByPlaceholder("123 Main Street").fill("Main Street");
    await page.getByPlaceholder("Lawrenceville").fill("Atlanta");
    await page.getByPlaceholder("30043").fill("30303");
    await page.getByRole("button", { name: /investigate/i }).click();

    await expect(page.getByText(/should include a number/i)).toBeVisible();
  });

  test("shows error for invalid state code", async ({ page }) => {
    await page.getByPlaceholder("123 Main Street").fill("123 Main St");
    await page.getByPlaceholder("Lawrenceville").fill("Atlanta");
    await page.getByPlaceholder("GA").clear();
    await page.getByPlaceholder("GA").fill("XX");
    await page.getByPlaceholder("30043").fill("30303");
    await page.getByRole("button", { name: /investigate/i }).click();

    await expect(page.getByText(/invalid state/i)).toBeVisible();
  });

  test("shows error for invalid ZIP format", async ({ page }) => {
    await page.getByPlaceholder("123 Main Street").fill("123 Main St");
    await page.getByPlaceholder("Lawrenceville").fill("Atlanta");
    await page.getByPlaceholder("30043").fill("123");
    await page.getByRole("button", { name: /investigate/i }).click();

    await expect(page.getByText(/valid 5-digit ZIP/i)).toBeVisible();
  });

  test("auto-uppercases state field", async ({ page }) => {
    const stateInput = page.getByPlaceholder("GA");
    await stateInput.clear();
    await stateInput.fill("ga");
    await expect(stateInput).toHaveValue("GA");
  });

  test("submit shows validating spinner", async ({ page }) => {
    await page.getByPlaceholder("123 Main Street").fill("123 Main St");
    await page.getByPlaceholder("Lawrenceville").fill("Atlanta");
    await page.getByPlaceholder("30043").fill("30303");
    await page.getByRole("button", { name: /investigate/i }).click();

    // Should show spinner (either validating text or the confirm step)
    await expect(
      page.getByText(/validating/i).or(page.getByText(/verified/i)).or(page.getByText(/not found/i))
    ).toBeVisible({ timeout: 10_000 });
  });
});

test.describe("Home Page — Dark Mode", () => {
  test("toggle switches theme and persists", async ({ page }) => {
    await page.goto("/");

    // Find the dark mode toggle button (moon icon button in nav)
    const toggle = page.locator("nav button").last();
    await expect(toggle).toBeVisible();

    // Click to enable dark mode
    await toggle.click();
    await expect(page.locator("html")).toHaveClass(/dark/);

    // Reload — should persist
    await page.reload();
    await expect(page.locator("html")).toHaveClass(/dark/);

    // Toggle back
    const toggle2 = page.locator("nav button").last();
    await toggle2.click();
    await expect(page.locator("html")).not.toHaveClass(/dark/);
  });
});

test.describe("Home Page — Layout", () => {
  test("header has logo and navigation links", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("link", { name: /eagle eye/i })).toBeVisible();
    await expect(page.getByRole("link", { name: /home/i })).toBeVisible();
    await expect(page.getByRole("link", { name: /search/i })).toBeVisible();
  });

  test("search link navigates to search page", async ({ page }) => {
    await page.goto("/");
    await page.getByRole("link", { name: /search/i }).click();
    await expect(page).toHaveURL(/\/search/);
    await expect(page.getByRole("heading", { name: /search/i })).toBeVisible();
  });
});
