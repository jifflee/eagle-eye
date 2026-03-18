# Context7 Integration Snippet

**Purpose:** Copy-paste this section into all agent system prompts to enable Context7 usage

---

## Documentation Lookup (Context7 MCP)

When working with external libraries, frameworks, or APIs, use Context7 MCP to access up-to-date documentation beyond Claude's training cutoff (April 2024).

### When to Use Context7

**Always query Context7 first when:**
1. Implementing features with external libraries (npm/PyPI packages)
2. Working with unfamiliar packages or frameworks
3. Checking version-specific API changes
4. Upgrading dependencies (review changelogs, migration guides)
5. Avoiding outdated patterns in rapidly-evolving libraries

**Skip Context7 for:**
- Standard language built-ins (Python, JavaScript core)
- Well-known stable APIs (fetch, console, etc.)
- Internal project code
- General programming concepts

### Available Tools

| Tool | Use Case | Example Query |
|------|----------|---------------|
| `search_docs` | Find feature documentation | `"fastapi dependency injection"` |
| `get_api_reference` | Deep API details | `"fastapi@0.109.0"` |
| `get_examples` | Usage patterns | `"react-hook-form validation"` |
| `get_changelog` | Version changes | `"prisma" from "4.x" to "5.x"` |
| `get_migration_guide` | Upgrade guides | `"vue" from "2.x" to "3.x"` |
| `get_package_info` | Version/metadata | `"react"` |

### Query Pattern

```
1. Check project's package.json/requirements.txt for versions
2. Query Context7 for version-specific documentation
3. Review current API patterns and best practices
4. Implement using up-to-date patterns
5. Document Context7 source in code comments
```

### Code Documentation

Always reference Context7 sources:

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

### Example Workflow

```
Task: Implement authentication with Passport.js

1. Check package.json: "passport": "^0.7.0"
2. Query Context7: search_docs("passport 0.7.x oauth strategy")
3. Query Context7: get_examples("passport oauth2")
4. Review current patterns from documentation
5. Implement using Passport 0.7.x API
6. Add source comments referencing Context7 query
```

**Full documentation:** [Context7 MCP Integration Guide](/docs/CONTEXT7_MCP_INTEGRATION.md)

---

**Instructions for Agent Maintainers:**

Copy the section above (from "## Documentation Lookup" to end) and paste into the system prompt of:
- Backend Developer Agent
- Frontend Developer Agent
- Architect Agent
- Security & IAM Agent
- Test & QA Agent
- All other agents that write code or make library decisions

Place after the "Role" section and before "Responsibilities".
