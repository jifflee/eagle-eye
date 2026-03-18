#!/usr/bin/env npx ts-node
/**
 * Fixture Generator Script
 *
 * Generates test fixtures from factory functions for consistent, type-safe test data.
 *
 * Usage:
 *   npx ts-node scripts/dev/generate-fixtures.ts
 *   npx ts-node scripts/dev/generate-fixtures.ts --output tests/fixtures/generated
 *   npx ts-node scripts/dev/generate-fixtures.ts --type users
 *
 * Environment:
 *   FIXTURE_OUTPUT_DIR - Override default output directory
 *
 * @see docs/standards/FIXTURE_CAPTURE.md for fixture standards
 */

import * as fs from 'fs';
import * as path from 'path';

// ============================================================
// Configuration
// ============================================================

const DEFAULT_OUTPUT_DIR = 'tests/fixtures/generated';

interface GeneratorConfig {
  outputDir: string;
  types: string[];
}

function parseArgs(): GeneratorConfig {
  const args = process.argv.slice(2);
  const config: GeneratorConfig = {
    outputDir: process.env.FIXTURE_OUTPUT_DIR || DEFAULT_OUTPUT_DIR,
    types: [],
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--output':
      case '-o':
        config.outputDir = args[++i];
        break;
      case '--type':
      case '-t':
        config.types.push(args[++i]);
        break;
      case '--help':
      case '-h':
        printUsage();
        process.exit(0);
    }
  }

  return config;
}

function printUsage(): void {
  console.log(`
Fixture Generator - Generate test fixtures from factories

Usage:
  npx ts-node scripts/dev/generate-fixtures.ts [options]

Options:
  --output, -o <dir>   Output directory (default: tests/fixtures/generated)
  --type, -t <type>    Generate only specific type (can be repeated)
  --help, -h           Show this help message

Examples:
  # Generate all fixtures
  npx ts-node scripts/dev/generate-fixtures.ts

  # Generate only user fixtures
  npx ts-node scripts/dev/generate-fixtures.ts --type users

  # Custom output directory
  npx ts-node scripts/dev/generate-fixtures.ts --output my-fixtures

Environment:
  FIXTURE_OUTPUT_DIR   Override default output directory
`);
}

// ============================================================
// Factory Types and Helpers
// ============================================================

/**
 * Base fixture metadata added to all generated fixtures
 */
interface FixtureMetadata {
  generatedAt: string;
  generator: string;
  version: string;
  notes?: string;
}

/**
 * Wrapper for generated fixtures with metadata
 */
interface GeneratedFixture<T> {
  _metadata: FixtureMetadata;
  data: T;
}

/**
 * Create fixture metadata
 */
function createMetadata(generator: string, notes?: string): FixtureMetadata {
  return {
    generatedAt: new Date().toISOString(),
    generator: `generate-fixtures.ts:${generator}`,
    version: '1.0.0',
    ...(notes && { notes }),
  };
}

/**
 * Wrap data with fixture metadata
 */
function wrapFixture<T>(data: T, generator: string, notes?: string): GeneratedFixture<T> {
  return {
    _metadata: createMetadata(generator, notes),
    data,
  };
}

// ============================================================
// Example Factory: Users
// ============================================================

interface User {
  id: string;
  email: string;
  name: string;
  role: 'user' | 'admin' | 'moderator';
  status: 'active' | 'inactive' | 'pending';
  createdAt: string;
  preferences?: {
    theme: 'light' | 'dark';
    notifications: boolean;
  };
}

let userIdCounter = 1;

/**
 * Create a user with optional overrides
 */
function createUser(overrides: Partial<User> = {}): User {
  const id = overrides.id || `user-${String(userIdCounter++).padStart(3, '0')}`;
  return {
    id,
    email: `${id}@example.com`,
    name: 'Test User',
    role: 'user',
    status: 'active',
    createdAt: new Date().toISOString(),
    ...overrides,
  };
}

/**
 * Generate user fixtures
 */
function generateUserFixtures(): GeneratedFixture<Record<string, User | User[]>> {
  // Reset counter for consistent output
  userIdCounter = 1;

  const fixtures = {
    validUser: createUser({
      id: 'user-001',
      email: 'valid@example.com',
      name: 'Valid User',
    }),
    adminUser: createUser({
      id: 'user-002',
      email: 'admin@example.com',
      name: 'Admin User',
      role: 'admin',
    }),
    moderatorUser: createUser({
      id: 'user-003',
      email: 'moderator@example.com',
      name: 'Moderator User',
      role: 'moderator',
    }),
    inactiveUser: createUser({
      id: 'user-004',
      email: 'inactive@example.com',
      name: 'Inactive User',
      status: 'inactive',
    }),
    pendingUser: createUser({
      id: 'user-005',
      email: 'pending@example.com',
      name: 'Pending User',
      status: 'pending',
    }),
    userWithPreferences: createUser({
      id: 'user-006',
      email: 'prefs@example.com',
      name: 'User With Preferences',
      preferences: {
        theme: 'dark',
        notifications: true,
      },
    }),
    userList: [
      createUser({ id: 'list-001', name: 'List User 1' }),
      createUser({ id: 'list-002', name: 'List User 2' }),
      createUser({ id: 'list-003', name: 'List User 3' }),
    ],
  };

  return wrapFixture(fixtures, 'users', 'Standard user fixtures for testing');
}

// ============================================================
// Example Factory: API Responses
// ============================================================

interface ApiResponse<T> {
  success: boolean;
  data: T;
  error?: {
    code: string;
    message: string;
  };
  pagination?: {
    page: number;
    limit: number;
    total: number;
    hasNext: boolean;
  };
}

/**
 * Create a success API response
 */
function createSuccessResponse<T>(data: T, pagination?: ApiResponse<T>['pagination']): ApiResponse<T> {
  return {
    success: true,
    data,
    ...(pagination && { pagination }),
  };
}

/**
 * Create an error API response
 */
function createErrorResponse<T>(code: string, message: string): ApiResponse<T> {
  return {
    success: false,
    data: null as unknown as T,
    error: { code, message },
  };
}

/**
 * Generate API response fixtures
 */
function generateApiResponseFixtures(): GeneratedFixture<Record<string, ApiResponse<unknown>>> {
  const fixtures = {
    successSingle: createSuccessResponse({
      id: 'item-001',
      name: 'Test Item',
    }),
    successList: createSuccessResponse(
      [
        { id: 'item-001', name: 'Item 1' },
        { id: 'item-002', name: 'Item 2' },
      ],
      {
        page: 1,
        limit: 10,
        total: 2,
        hasNext: false,
      }
    ),
    successPaginated: createSuccessResponse(
      [
        { id: 'item-001', name: 'Item 1' },
        { id: 'item-002', name: 'Item 2' },
      ],
      {
        page: 1,
        limit: 2,
        total: 100,
        hasNext: true,
      }
    ),
    errorNotFound: createErrorResponse('NOT_FOUND', 'Resource not found'),
    errorUnauthorized: createErrorResponse('UNAUTHORIZED', 'Authentication required'),
    errorForbidden: createErrorResponse('FORBIDDEN', 'Access denied'),
    errorValidation: createErrorResponse('VALIDATION_ERROR', 'Invalid input data'),
    errorServer: createErrorResponse('INTERNAL_ERROR', 'An unexpected error occurred'),
  };

  return wrapFixture(fixtures, 'api-responses', 'Standard API response patterns');
}

// ============================================================
// Example Factory: Form Validation
// ============================================================

interface ValidationCase {
  input: Record<string, unknown>;
  valid: boolean;
  errors?: string[];
}

/**
 * Generate form validation test cases
 */
function generateValidationFixtures(): GeneratedFixture<Record<string, ValidationCase[]>> {
  const fixtures = {
    emailValidation: [
      { input: { email: 'valid@example.com' }, valid: true },
      { input: { email: 'another.valid@example.co.uk' }, valid: true },
      { input: { email: '' }, valid: false, errors: ['Email is required'] },
      { input: { email: 'invalid' }, valid: false, errors: ['Invalid email format'] },
      { input: { email: 'missing@domain' }, valid: false, errors: ['Invalid email format'] },
      { input: { email: '@nodomain.com' }, valid: false, errors: ['Invalid email format'] },
    ],
    passwordValidation: [
      { input: { password: 'ValidPass123!' }, valid: true },
      { input: { password: 'AnotherValid1@' }, valid: true },
      { input: { password: '' }, valid: false, errors: ['Password is required'] },
      { input: { password: 'short' }, valid: false, errors: ['Password must be at least 8 characters'] },
      { input: { password: 'nouppercase1!' }, valid: false, errors: ['Password must contain uppercase letter'] },
      { input: { password: 'NOLOWERCASE1!' }, valid: false, errors: ['Password must contain lowercase letter'] },
      { input: { password: 'NoNumbers!' }, valid: false, errors: ['Password must contain a number'] },
    ],
    phoneValidation: [
      { input: { phone: '+1-555-000-0000' }, valid: true },
      { input: { phone: '555-000-0000' }, valid: true },
      { input: { phone: '5550000000' }, valid: true },
      { input: { phone: '' }, valid: true }, // Optional field
      { input: { phone: '123' }, valid: false, errors: ['Invalid phone number'] },
      { input: { phone: 'not-a-phone' }, valid: false, errors: ['Invalid phone number'] },
    ],
  };

  return wrapFixture(fixtures, 'validation', 'Form validation test cases');
}

// ============================================================
// Generator Registry
// ============================================================

type FixtureGenerator = () => GeneratedFixture<unknown>;

const generators: Map<string, FixtureGenerator> = new Map([
  ['users', generateUserFixtures],
  ['api-responses', generateApiResponseFixtures],
  ['validation', generateValidationFixtures],
]);

// ============================================================
// Main Generator
// ============================================================

function ensureDirectory(dir: string): void {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    console.log(`Created directory: ${dir}`);
  }
}

function writeFixture(filepath: string, data: unknown): void {
  const content = JSON.stringify(data, null, 2);
  fs.writeFileSync(filepath, content + '\n');
  console.log(`Generated: ${filepath}`);
}

function main(): void {
  const config = parseArgs();

  console.log('='.repeat(60));
  console.log('Fixture Generator');
  console.log('='.repeat(60));
  console.log(`Output directory: ${config.outputDir}`);
  console.log();

  ensureDirectory(config.outputDir);

  const typesToGenerate = config.types.length > 0 ? config.types : Array.from(generators.keys());

  for (const type of typesToGenerate) {
    const generator = generators.get(type);
    if (!generator) {
      console.error(`Unknown fixture type: ${type}`);
      console.error(`Available types: ${Array.from(generators.keys()).join(', ')}`);
      process.exit(1);
    }

    const fixture = generator();
    const filepath = path.join(config.outputDir, `${type}.json`);
    writeFixture(filepath, fixture);
  }

  console.log();
  console.log('='.repeat(60));
  console.log(`Generated ${typesToGenerate.length} fixture file(s)`);
  console.log('='.repeat(60));

  // Generate index file
  const indexPath = path.join(config.outputDir, 'index.json');
  const index = {
    _metadata: createMetadata('index', 'Index of generated fixtures'),
    fixtures: typesToGenerate.map((type) => ({
      type,
      file: `${type}.json`,
      generatedAt: new Date().toISOString(),
    })),
  };
  writeFixture(indexPath, index);
}

// Run if called directly
main();
