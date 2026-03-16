/** Client-side address validation (instant, no API call). */

export interface AddressFields {
  street: string;
  city: string;
  state: string;
  zip: string;
}

export interface ValidationResult {
  valid: boolean;
  errors: Record<string, string>;
}

const STATE_CODES = new Set([
  "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA",
  "KS","KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ",
  "NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN","TX","UT","VT",
  "VA","WA","WV","WI","WY","DC",
]);

export function validateAddress(addr: AddressFields): ValidationResult {
  const errors: Record<string, string> = {};

  if (!addr.street.trim()) {
    errors.street = "Street address is required";
  } else if (!/\d/.test(addr.street)) {
    errors.street = "Street address should include a number";
  }

  if (!addr.city.trim()) {
    errors.city = "City is required";
  }

  const state = addr.state.trim().toUpperCase();
  if (!state) {
    errors.state = "State is required";
  } else if (!STATE_CODES.has(state)) {
    errors.state = "Invalid state code";
  }

  const zip = addr.zip.trim();
  if (!zip) {
    errors.zip = "ZIP code is required";
  } else if (!/^\d{5}(-\d{4})?$/.test(zip)) {
    errors.zip = "Enter a valid 5-digit ZIP";
  }

  return { valid: Object.keys(errors).length === 0, errors };
}
