#!/usr/bin/env npx ts-node
/**
 * Fixture Regeneration Script
 *
 * Regenerate test fixtures from factory functions after schema changes.
 * This ensures fixtures stay in sync with model definitions while preserving
 * stable test IDs and other test-specific values.
 *
 * Usage:
 *   npx ts-node scripts/maintenance/regenerate-fixtures.ts
 *   npx ts-node scripts/maintenance/regenerate-fixtures.ts --model User
 *   npx ts-node scripts/maintenance/regenerate-fixtures.ts --dry-run
 *   npx ts-node scripts/maintenance/regenerate-fixtures.ts --help
 *
 * Options:
 *   --model <name>    Regenerate only fixtures for specific model
 *   --dry-run         Show what would be regenerated without writing files
 *   --verbose         Show detailed output
 *   --help            Show this help message
 *
 * Environment:
 *   FIXTURE_DIR       Override default fixture directory (default: tests/fixtures)
 *
 * @see docs/standards/FIXTURE_MAINTENANCE.md for fixture maintenance guide
 */

import * as fs from 'fs';
import * as path from 'path';

// ============================================================
// Configuration
// ============================================================

const DEFAULT_FIXTURE_DIR = 'tests/fixtures';

interface RegenerateConfig {
  model?: string;
  dryRun: boolean;
  verbose: boolean;
  fixtureDir: string;
}

interface FixtureMetadata {
  regeneratedAt: string;
  regeneratedBy: string;
  originalFile?: string;
  schemaVersion?: string;
  notes?: string;
}

// ============================================================
// Argument Parsing
// ============================================================

function parseArgs(): RegenerateConfig {
  const args = process.argv.slice(2);
  const config: RegenerateConfig = {
    dryRun: false,
    verbose: false,
    fixtureDir: process.env.FIXTURE_DIR || DEFAULT_FIXTURE_DIR,
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--model':
      case '-m':
        config.model = args[++i];
        break;
      case '--dry-run':
      case '-d':
        config.dryRun = true;
        break;
      case '--verbose':
      case '-v':
        config.verbose = true;
        break;
      case '--help':
      case '-h':
        printUsage();
        process.exit(0);
      default:
        console.error(`Unknown option: ${args[i]}`);
        printUsage();
        process.exit(1);
    }
  }

  return config;
}

function printUsage(): void {
  console.log(`
Fixture Regeneration Script

Usage:
  npx ts-node scripts/maintenance/regenerate-fixtures.ts [options]

Options:
  --model, -m <name>   Regenerate only fixtures for specific model
  --dry-run, -d        Show what would be regenerated without writing files
  --verbose, -v        Show detailed output
  --help, -h           Show this help message

Examples:
  # Regenerate all fixtures
  npx ts-node scripts/maintenance/regenerate-fixtures.ts

  # Regenerate only User fixtures
  npx ts-node scripts/maintenance/regenerate-fixtures.ts --model User

  # Preview what would be regenerated
  npx ts-node scripts/maintenance/regenerate-fixtures.ts --dry-run

  # Verbose mode
  npx ts-node scripts/maintenance/regenerate-fixtures.ts --model User --verbose

Environment:
  FIXTURE_DIR   Override default fixture directory (default: tests/fixtures)

Notes:
  - Stable IDs and test-specific values are preserved
  - Factories must be defined in tests/factories/
  - Regenerated fixtures include metadata tracking
  - Always run tests after regeneration
`);
}

// ============================================================
// Factory Functions (Examples - Replace with actual imports)
// ============================================================

/**
 * Example User factory
 * In production, import from: import { createUser } from '../tests/factories/user.factory';
 */
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

function createUser(overrides: Partial<User> = {}): User {
  return {
    id: overrides.id || `user-${Date.now()}`,
    email: overrides.email || 'user@example.com',
    name: overrides.name || 'Test User',
    role: overrides.role || 'user',
    status: overrides.status || 'active',
    createdAt: overrides.createdAt || new Date().toISOString(),
    ...overrides,
  };
}

/**
 * Example Product factory
 * In production, import from: import { createProduct } from '../tests/factories/product.factory';
 */
interface Product {
  id: string;
  name: string;
  description: string;
  price: number;
  currency: string;
  inStock: boolean;
}

function createProduct(overrides: Partial<Product> = {}): Product {
  return {
    id: overrides.id || `product-${Date.now()}`,
    name: overrides.name || 'Test Product',
    description: overrides.description || 'A test product',
    price: overrides.price || 9.99,
    currency: overrides.currency || 'USD',
    inStock: overrides.inStock !== undefined ? overrides.inStock : true,
    ...overrides,
  };
}

// ============================================================
// Fixture Definitions
// ============================================================

/**
 * Define fixtures to regenerate
 * Key: filepath relative to FIXTURE_DIR
 * Value: factory function call with stable overrides
 */

const USER_FIXTURES: Record<string, User> = {
  'users/valid-user.json': createUser({
    id: 'user-123',
    email: 'test@example.com',
    name: 'Test User',
    role: 'user',
    status: 'active',
  }),

  'users/admin-user.json': createUser({
    id: 'admin-001',
    email: 'admin@example.com',
    name: 'Admin User',
    role: 'admin',
    status: 'active',
  }),

  'users/moderator-user.json': createUser({
    id: 'mod-001',
    email: 'moderator@example.com',
    name: 'Moderator User',
    role: 'moderator',
    status: 'active',
  }),

  'users/inactive-user.json': createUser({
    id: 'user-inactive',
    email: 'inactive@example.com',
    name: 'Inactive User',
    role: 'user',
    status: 'inactive',
  }),

  'users/pending-user.json': createUser({
    id: 'user-pending',
    email: 'pending@example.com',
    name: 'Pending User',
    role: 'user',
    status: 'pending',
  }),

  'users/user-with-preferences.json': createUser({
    id: 'user-prefs',
    email: 'prefs@example.com',
    name: 'User With Preferences',
    role: 'user',
    status: 'active',
    preferences: {
      theme: 'dark',
      notifications: true,
    },
  }),
};

const PRODUCT_FIXTURES: Record<string, Product> = {
  'products/basic-product.json': createProduct({
    id: 'product-001',
    name: 'Basic Product',
    description: 'A basic test product',
    price: 19.99,
  }),

  'products/expensive-product.json': createProduct({
    id: 'product-002',
    name: 'Expensive Product',
    description: 'An expensive test product',
    price: 999.99,
  }),

  'products/out-of-stock.json': createProduct({
    id: 'product-003',
    name: 'Out of Stock Product',
    description: 'Product that is out of stock',
    price: 29.99,
    inStock: false,
  }),
};

// Registry of all fixture sets by model
const FIXTURE_REGISTRY: Record<string, Record<string, unknown>> = {
  User: USER_FIXTURES,
  Product: PRODUCT_FIXTURES,
};

// ============================================================
// Regeneration Logic
// ============================================================

function createMetadata(filepath: string): FixtureMetadata {
  return {
    regeneratedAt: new Date().toISOString(),
    regeneratedBy: 'scripts/maintenance/regenerate-fixtures.ts',
    originalFile: filepath,
    notes: 'Auto-regenerated from factory to match current schema',
  };
}

function wrapWithMetadata(data: unknown, filepath: string): unknown {
  return {
    _metadata: createMetadata(filepath),
    ...data,
  };
}

function writeFixture(filepath: string, data: unknown, dryRun: boolean, verbose: boolean): void {
  const content = JSON.stringify(data, null, 2) + '\n';

  if (dryRun) {
    console.log(`[DRY RUN] Would regenerate: ${filepath}`);
    if (verbose) {
      console.log('Content preview:');
      console.log(content.split('\n').slice(0, 10).join('\n'));
      console.log('...\n');
    }
  } else {
    // Ensure directory exists
    const dir = path.dirname(filepath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    fs.writeFileSync(filepath, content);
    console.log(`✓ Regenerated: ${filepath}`);

    if (verbose) {
      const stats = fs.statSync(filepath);
      console.log(`  Size: ${stats.size} bytes`);
      console.log(`  Fields: ${Object.keys(data as object).length}`);
    }
  }
}

function regenerateFixtures(config: RegenerateConfig): void {
  console.log('═══════════════════════════════════════════════════════════');
  console.log('Fixture Regeneration');
  console.log('═══════════════════════════════════════════════════════════');
  console.log();
  console.log(`Mode: ${config.dryRun ? 'DRY RUN' : 'WRITE'}`);
  console.log(`Fixture directory: ${config.fixtureDir}`);
  if (config.model) {
    console.log(`Model filter: ${config.model}`);
  }
  console.log();

  let totalRegenerated = 0;
  const modelsToRegenerate = config.model
    ? [config.model]
    : Object.keys(FIXTURE_REGISTRY);

  for (const modelName of modelsToRegenerate) {
    const fixtures = FIXTURE_REGISTRY[modelName];

    if (!fixtures) {
      console.error(`ERROR: No fixtures defined for model: ${modelName}`);
      console.log();
      console.log('Available models:');
      Object.keys(FIXTURE_REGISTRY).forEach((m) => console.log(`  - ${m}`));
      process.exit(1);
    }

    console.log(`## Regenerating ${modelName} fixtures`);
    console.log();

    Object.entries(fixtures).forEach(([relativePath, data]) => {
      const filepath = path.join(config.fixtureDir, relativePath);
      const wrappedData = wrapWithMetadata(data, filepath);

      writeFixture(filepath, wrappedData, config.dryRun, config.verbose);
      totalRegenerated++;
    });

    console.log();
  }

  console.log('═══════════════════════════════════════════════════════════');
  console.log('Summary');
  console.log('═══════════════════════════════════════════════════════════');
  console.log();

  if (config.dryRun) {
    console.log(`Would regenerate ${totalRegenerated} fixture(s)`);
    console.log();
    console.log('Run without --dry-run to apply changes');
  } else {
    console.log(`✓ Regenerated ${totalRegenerated} fixture(s)`);
    console.log();
    console.log('Next steps:');
    console.log('  1. Review regenerated fixtures: git diff tests/fixtures/');
    console.log('  2. Validate fixtures: npm run fixtures:validate');
    console.log('  3. Run tests: npm test');
    console.log('  4. Commit if tests pass: git add tests/fixtures/ && git commit -m "test: regenerate fixtures"');
  }

  console.log();
}

// ============================================================
// Main
// ============================================================

function main(): void {
  try {
    const config = parseArgs();
    regenerateFixtures(config);
  } catch (error) {
    console.error('Error:', error instanceof Error ? error.message : error);
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  main();
}
