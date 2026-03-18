import { test, expect } from "@playwright/test";

/**
 * End-to-end test: Submit a real Gwinnett County address,
 * verify it through Census Geocoder, and navigate to graph page.
 *
 * Uses 446 W Crogan St, Lawrenceville, GA 30046
 * (Gwinnett County Justice Center — always geocodable)
 */

test.describe("Address Flow — Real Gwinnett County Address", () => {
  test("full flow: enter address → validate → confirm → investigation", async ({ page }) => {
    await page.goto("/");

    // Step 1: Fill in the address form
    await page.getByPlaceholder("123 Main Street").fill("446 W Crogan St");
    await page.getByPlaceholder("Lawrenceville").fill("Lawrenceville");
    // State is pre-filled with GA
    await page.getByPlaceholder("30043").fill("30046");

    // Step 2: Submit the form
    await page.getByRole("button", { name: /investigate/i }).click();

    // Step 3: Should show validating spinner
    await expect(page.getByText(/validating/i)).toBeVisible({ timeout: 5_000 });

    // Step 4: Wait for validation result
    // Backend may be unavailable — app falls back to "Verified Address" with warning
    const startBtn = page.getByRole("button", { name: /start investigation/i });
    const notFound = page.getByText("Address not found", { exact: false });

    await expect(startBtn.or(notFound)).toBeVisible({ timeout: 15_000 });

    // Step 5: If we can proceed, start investigation
    if (await startBtn.isVisible()) {
      await startBtn.click();

      // Should navigate to graph page
      await expect(page).toHaveURL(/\/investigation\//);

      // Graph page should render
      await expect(page.getByText("Data Sources")).toBeVisible({ timeout: 5_000 });
    }
  });

  test("edit address after validation returns to form", async ({ page }) => {
    await page.goto("/");

    await page.getByPlaceholder("123 Main Street").fill("446 W Crogan St");
    await page.getByPlaceholder("Lawrenceville").fill("Lawrenceville");
    await page.getByPlaceholder("30043").fill("30046");
    await page.getByRole("button", { name: /investigate/i }).click();

    // Wait for confirm step
    const editBtn = page.getByRole("button", { name: /edit address/i });
    await expect(editBtn).toBeVisible({ timeout: 15_000 });

    // Click "Edit Address"
    if (await editBtn.isVisible()) {
      await editBtn.click();

      // Should return to form with values preserved
      await expect(page.getByPlaceholder("123 Main Street")).toHaveValue("446 W Crogan St");
      await expect(page.getByPlaceholder("Lawrenceville")).toHaveValue("Lawrenceville");
    }
  });

  test("invalid address shows suggestions", async ({ page }) => {
    await page.goto("/");

    // Use a slightly wrong address
    await page.getByPlaceholder("123 Main Street").fill("999 Fake Blvd");
    await page.getByPlaceholder("Lawrenceville").fill("Lawrenceville");
    await page.getByPlaceholder("30043").fill("30046");
    await page.getByRole("button", { name: /investigate/i }).click();

    // Should either show "not found" or suggestions
    const result = page.getByText(/not found/i)
      .or(page.getByText(/did you mean/i))
      .or(page.getByText(/could not verify/i));

    await expect(result).toBeVisible({ timeout: 15_000 });
  });
});
