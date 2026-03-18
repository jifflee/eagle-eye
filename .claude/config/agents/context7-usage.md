# Context7 Usage Guidelines for Agents

**Purpose:** Standard guidelines for all agents when using Context7 MCP for documentation lookup

---

## When to Use Context7

All agents should proactively query Context7 when:

### 1. Implementing with External Libraries
- Any npm/PyPI package not built into the language
- Framework-specific features (React, Vue, FastAPI, Django, etc.)
- Third-party APIs and SDKs

**Example:**
```
Task: Add form validation with React Hook Form
Action: Query Context7 for react-hook-form current API
```

### 2. Version-Specific Requirements
- Project specifies exact library versions
- Need to check compatibility between packages
- Upgrading dependencies

**Example:**
```
Task: Upgrade Prisma from 4.x to 5.x
Action: Query changelog and migration guide via Context7
```

### 3. Unfamiliar Territory
- First time using a particular library
- Uncertain about current best practices
- Framework patterns you haven't used recently

**Example:**
```
Task: Implement Fastify middleware
Action: Query Context7 for Fastify 4.x middleware patterns
```

### 4. Avoiding Outdated Patterns
- Libraries that evolve rapidly (React, Next.js, etc.)
- Frameworks with recent major versions
- Breaking changes between versions

**Example:**
```
Task: Build Next.js App Router page
Action: Query Context7 for Next.js 14 App Router patterns
```

---

## When NOT to Use Context7

Skip Context7 for:

- **Standard language features:** Python built-ins, JavaScript Array methods, etc.
- **Well-known stable APIs:** fetch(), console.log(), basic file I/O
- **Internal project code:** Your own project's modules and functions
- **General concepts:** REST principles, design patterns, algorithms

---

## Query Strategy

### Good Queries

✅ **Specific and version-aware:**
- "fastapi 0.109.0 dependency injection"
- "react-hook-form 7.x validation schema"
- "prisma 5.x client api"

✅ **Feature-focused:**
- "next.js 14 server components"
- "vue 3 composition api"
- "express middleware error handling"

✅ **Problem-oriented:**
- "fastify request validation best practices"
- "react query cache invalidation"
- "django rest framework authentication"

### Bad Queries

❌ **Too generic:**
- "fastapi" (too broad)
- "react" (no specific feature)
- "api" (meaningless without context)

❌ **Standard language:**
- "python list comprehension"
- "javascript promise"
- "typescript interface"

❌ **Outdated when Claude knows current:**
- "express middleware" (Express is stable, Claude knows it)
- "lodash array methods" (stable API)

---

## Code Documentation Pattern

Always document Context7 sources in your code:

### Good Examples

```typescript
// Using Fastify 4.26.0 schema-based validation
// Source: Context7 query 2026-02-06
// Ref: https://fastify.dev/docs/latest/Reference/Validation-and-Serialization/
server.post('/api/users', {
  schema: {
    body: {
      type: 'object',
      required: ['email'],
      properties: {
        email: { type: 'string', format: 'email' }
      }
    }
  }
}, handler);
```

```python
# Using FastAPI 0.109.0 dependency injection
# Source: Context7 query 2026-02-06
from fastapi import Depends

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

@app.get("/users")
def read_users(db: Session = Depends(get_db)):
    return db.query(User).all()
```

### Bad Examples

```typescript
// BAD: No source attribution
server.post('/api/users', { schema: { ... } }, handler);

// BAD: Vague reference
// Using Fastify validation (unclear which version/pattern)
```

---

## Workflow Examples

### Example 1: Backend Developer Agent

**Task:** Implement REST API with Fastify

**Workflow:**
1. Check project's package.json for Fastify version
2. Query Context7: `get_api_reference("fastify@4.26.0")`
3. Query Context7: `search_docs("fastify 4.x validation")`
4. Review current patterns from Context7
5. Implement using version-specific API
6. Add Context7 source comments to code

### Example 2: Frontend Developer Agent

**Task:** Add form handling to React component

**Workflow:**
1. Check React version in package.json
2. Query Context7: `search_docs("react-hook-form validation")`
3. Query Context7: `get_examples("react-hook-form zod integration")`
4. Review examples and current patterns
5. Implement form with up-to-date hooks
6. Document Context7 source in comments

### Example 3: Architect Agent

**Task:** Design authentication system

**Workflow:**
1. Query Context7 for auth libraries:
   - `get_package_info("passport")`
   - `get_package_info("jsonwebtoken")`
   - `search_docs("passport jwt strategy")`
2. Check compatibility and versions
3. Review security best practices from docs
4. Design architecture using current patterns
5. Document library versions and sources

---

## Available Context7 Tools

| Tool | When to Use | Example |
|------|-------------|---------|
| `search_docs` | Find documentation for specific features | `search_docs("fastapi dependency injection")` |
| `get_package_info` | Check versions, dependencies | `get_package_info("react")` |
| `get_api_reference` | Deep dive into API details | `get_api_reference("fastify@4.26.0")` |
| `get_examples` | Learn usage patterns | `get_examples("react-hook-form validation")` |
| `get_changelog` | Understand version changes | `get_changelog("prisma", "4.x", "5.x")` |
| `get_migration_guide` | Upgrade between versions | `get_migration_guide("vue", "2.x", "3.x")` |

---

## Best Practices

### DO:
- ✅ Query Context7 BEFORE implementing unfamiliar libraries
- ✅ Check version-specific documentation
- ✅ Use specific queries (include version numbers)
- ✅ Document Context7 sources in code comments
- ✅ Verify package.json versions before querying
- ✅ Check changelogs when upgrading dependencies

### DON'T:
- ❌ Skip Context7 and guess at library APIs
- ❌ Query for standard language features
- ❌ Use generic queries without version context
- ❌ Implement without documenting sources
- ❌ Trust training data for rapidly-evolving libraries
- ❌ Query repeatedly for the same information (cache results)

---

## Troubleshooting

### Context7 Returns No Results

**Possible causes:**
- Package name misspelled
- Package not on npm/PyPI
- Too generic query

**Solutions:**
- Verify package name in package.json or requirements.txt
- Try alternate query terms
- Add version constraint to query
- Check package exists: `npm info <package>` or `pip search <package>`

### Documentation Seems Outdated

**Possible causes:**
- Cache hit with stale data
- Package docs not updated

**Solutions:**
- Specify exact version in query: `"package@x.y.z"`
- Clear cache: `rm -rf ~/.cache/context7`
- Cross-reference with official package website

### Query Taking Too Long

**Possible causes:**
- Network latency
- Cache miss requiring fetch
- Large documentation set

**Solutions:**
- Wait for response (first query is slowest)
- Subsequent queries will be cached
- Use more specific queries to reduce doc size

---

## Integration with Agent Workflow

### Pre-Implementation Phase

```
1. Architect Agent designs system
   └─> Queries Context7 for library compatibility

2. Backend/Frontend Developer receives task
   └─> Queries Context7 for current API patterns
   └─> Reviews examples and best practices
   └─> Begins implementation with up-to-date knowledge
```

### During Implementation

```
Developer Agent working on feature:
1. Encounters unfamiliar library method
2. Queries Context7 for API reference
3. Reviews current usage pattern
4. Implements correctly
5. Documents source in code comment
```

### Code Review Phase

```
Code Reviewer Agent:
1. Sees Context7 source comments
2. Validates implementation matches referenced docs
3. Checks version consistency with package.json
4. Approves or requests changes
```

---

## Agent-Specific Guidance

### Backend Developer Agent
**Primary use cases:**
- Framework APIs (FastAPI, Express, Django)
- Database drivers (Prisma, SQLAlchemy, Mongoose)
- Authentication libraries (Passport, OAuth)
- Validation libraries (Zod, Pydantic, Joi)

### Frontend Developer Agent
**Primary use cases:**
- React/Vue/Angular APIs
- Form libraries (react-hook-form, Formik)
- State management (Zustand, Pinia, Redux)
- UI component libraries (Material-UI, Chakra UI)

### Architect Agent
**Primary use cases:**
- Framework architectural patterns
- Library compatibility matrices
- Performance characteristics
- Security best practices

### Test & QA Agent
**Primary use cases:**
- Testing framework APIs (Jest, Pytest, Vitest)
- Mocking libraries (MSW, nock)
- Assertion libraries (Chai, testing-library)

### Security & IAM Agent
**Primary use cases:**
- Security library APIs (Helmet, CORS)
- Authentication patterns (OAuth, JWT)
- Encryption libraries (bcrypt, crypto)

---

## Performance Tips

### Caching
- Context7 caches results for 24 hours (default)
- Queries for same package/version reuse cache
- Cache location: `~/.cache/context7`

### Batch Related Queries
When starting a new feature:
```
# GOOD: Batch queries at start
1. get_package_info("fastify")
2. get_api_reference("fastify@4.26.0")
3. get_examples("fastify validation")
[Now implement with cached docs]

# BAD: Query for every method
1. Implement line 1... query Context7
2. Implement line 2... query Context7
3. Implement line 3... query Context7
```

### Strategic Querying
```
# Query once, implement many
const docs = await context7.get_api_reference("react-hook-form@7.x");

// Now implement entire form using cached knowledge
// No need to query for each hook or method
```

---

## Metrics

Track Context7 usage in audit logs:

```bash
# View Context7 queries
jq -r 'select(.tool | contains("context7")) | {time: .timestamp, tool: .tool, query: .query}' \
  .claude/permission-audit.jsonl

# Count queries by package
jq -r 'select(.tool == "search_docs") | .package' \
  .claude/permission-audit.jsonl | sort | uniq -c | sort -rn
```

---

## Related Documentation

- [Context7 MCP Integration Guide](/docs/CONTEXT7_MCP_INTEGRATION.md) - Complete integration guide
- [Agent Permissions](/docs/AGENT_PERMISSIONS.md) - Permission system
- [Claude Agent SDK Integration](/docs/CLAUDE_SDK_INTEGRATION.md) - SDK patterns

---

**Remember:** Context7 is a tool to keep you current. When in doubt, query first, implement second.
