# Eagle Eye: Design System & Visual Specifications

**Version:** 1.0
**Date:** 2026-03-16
**Status:** Design Guidelines for Frontend Implementation

---

## 1. COLOR PALETTE

### Primary Brand Colors
- **Primary Blue:** #3B82F6 (Used for CTAs, active states)
- **Neutral Gray:** #6B7280 (Secondary text, borders)
- **Success Green:** #10B981 (Positive actions, owned entities)
- **Error Red:** #EF4444 (Alerts, legal issues)
- **Warning Orange:** #F59E0B (Caution states)

### Entity Type Colors (Graph Nodes)
- **Person:** #3B82F6 (Blue)
- **Address:** #F59E0B (Orange)
- **Business:** #10B981 (Green)
- **Vehicle:** #8B5CF6 (Purple)
- **Court Case:** #EF4444 (Red)
- **Property Record:** #6B7280 (Gray)
- **Legal Entity:** #14B8A6 (Teal)
- **Phone Number:** #EC4899 (Pink)
- **Email Address:** #6366F1 (Indigo)
- **Organization:** #06B6D4 (Cyan)

### Background Colors
- **Page Background:** #FFFFFF (White)
- **Sidebar Background:** #F9FAFB (Off-white, #f3f4f6 with 1px border #e5e7eb)
- **Card Background:** #FFFFFF with subtle shadow
- **Hover State:** #F0F9FF (Light blue tint)
- **Selected State:** #FCD34D (Gold highlight)

### Semantic Colors
- **Success:** #10B981 (Green for complete, verified)
- **Warning:** #F59E0B (Orange for incomplete, timeout)
- **Error:** #EF4444 (Red for failed, critical)
- **Info:** #3B82F6 (Blue for informational messages)
- **Disabled:** #D1D5DB (Gray, 60% opacity)

---

## 2. TYPOGRAPHY

### Font Family
- **Primary:** Inter, Segoe UI, -apple-system, BlinkMacSystemFont, system-ui, sans-serif
- **Monospace (for IDs, code):** Menlo, Monaco, Courier New, monospace

### Type Scale (Responsive)
```
Display: 32px / 40px (address header, main titles)
Heading 1: 28px / 36px (dashboard section titles)
Heading 2: 24px / 32px (card titles)
Heading 3: 20px / 28px (subsection titles)
Body Large: 16px / 24px (main content, labels)
Body Regular: 14px / 20px (form inputs, descriptions)
Body Small: 12px / 16px (secondary text, hints, source attribution)
Caption: 11px / 14px (legends, microcopy, timestamps)
```

### Font Weights
- **Bold:** 700 (headers, entity names in nodes)
- **Semibold:** 600 (subheaders, strong emphasis)
- **Regular:** 400 (body text)
- **Light:** 300 (subtle text, disabled states)

### Line Height
- **Headings:** 1.2 (tight spacing)
- **Body:** 1.5 (comfortable reading)
- **Code:** 1.4 (monospace)

---

## 3. SPACING & LAYOUT

### Spacing Scale (8px grid)
```
0.5 rem (4px) - xs (tight spacing between inline elements)
1 rem (8px) - sm (small padding/margin)
1.5 rem (12px) - md (medium spacing)
2 rem (16px) - lg (standard padding/margin)
2.5 rem (20px) - xl (larger spacing)
3 rem (24px) - 2xl (section spacing)
4 rem (32px) - 3xl (major spacing between sections)
```

### Layout Grid
- **Container width:** 1400px max (for desktop)
- **Dashboard sidebar:** 300px (fixed or collapsible)
- **Entity detail panel:** 350–400px (right side, fixed)
- **Graph canvas:** Remaining width (min 600px)
- **Responsive breakpoints:**
  - Mobile: 320px–640px (not in MVP)
  - Tablet: 640px–1024px (not in MVP)
  - Desktop: 1024px+

### Gutter / Margin Rules
- Between major sections: 32px (2 * lg)
- Between cards/rows: 16px (lg)
- Between inline elements: 8px (sm)
- Card padding: 16px–20px
- Input field padding: 10px (vertical) × 12px (horizontal)

---

## 4. COMPONENT STYLES

### Buttons

**Primary Button (CTA)**
- Background: #3B82F6 (blue)
- Text: White, bold
- Padding: 10px 16px
- Border radius: 6px
- Hover: Background #2563EB (darker blue)
- Active: Background #1D4ED8 (even darker)
- Disabled: Background #D1D5DB (gray), cursor not-allowed

**Secondary Button**
- Background: #F3F4F6 (light gray)
- Text: #1F2937 (dark gray)
- Border: 1px solid #D1D5DB
- Padding: 10px 16px
- Border radius: 6px
- Hover: Background #E5E7EB
- Active: Background #D1D5DB

**Tertiary / Ghost Button**
- Background: transparent
- Text: #3B82F6 (blue)
- Border: 1px solid #3B82F6
- Padding: 10px 16px
- Border radius: 6px
- Hover: Background #F0F9FF, border #2563EB

**Icon Button**
- Background: transparent
- Icon: 20px × 20px, color #6B7280
- Hover: Background #F3F4F6, icon #1F2937
- Padding: 8px (square)

### Form Inputs

**Text Input**
- Background: #FFFFFF
- Border: 1px solid #D1D5DB
- Padding: 10px 12px
- Border radius: 6px
- Font: 14px, regular
- Hover: Border #9CA3AF (lighter)
- Focus: Border #3B82F6 (blue), box-shadow 0 0 0 3px rgba(59, 130, 246, 0.1)
- Disabled: Background #F3F4F6, color #9CA3AF, cursor not-allowed

**Dropdown / Select**
- Same as text input + chevron icon on right
- Option text: 14px, regular

**Checkbox / Radio**
- Size: 16px × 16px
- Border: 1px solid #D1D5DB
- Checked: Background #3B82F6, border #3B82F6
- Hover: Border #9CA3AF
- Focus: box-shadow 0 0 0 3px rgba(59, 130, 246, 0.1)

**Slider / Range Input**
- Track: #E5E7EB (light gray), height 4px
- Thumb: #3B82F6 (blue), 16px × 16px, border-radius 50%
- Hover thumb: Background #2563EB
- Focus: box-shadow 0 0 0 3px rgba(59, 130, 246, 0.1)

### Cards

**Standard Card**
- Background: #FFFFFF
- Border: 1px solid #E5E7EB
- Border radius: 8px
- Padding: 16px (or 20px for large)
- Shadow: 0 1px 3px rgba(0, 0, 0, 0.1), 0 1px 2px rgba(0, 0, 0, 0.06)
- Hover: Shadow 0 4px 6px rgba(0, 0, 0, 0.1), 0 2px 4px rgba(0, 0, 0, 0.06)
- Overflow: Hidden (rounded corners clipped)

**Collapsible Card**
- Chevron icon (top-right) rotates 180° on expand
- Content animates: max-height 0 → 500px (300ms ease-out)
- Transition: opacity 0 → 1 (200ms offset)

### Badges / Tags

**Entity Type Badge**
- Background: Entity type color (e.g., #3B82F6 for person)
- Text: White, 11px, bold
- Padding: 4px 8px
- Border radius: 12px (pill shape)

**Status Badge**
- Same as entity badge, but color matches status:
  - Success (#10B981 green): ✓ Complete
  - Warning (#F59E0B orange): ⟳ Querying
  - Error (#EF4444 red): ✗ Failed
  - Info (#3B82F6 blue): ⓘ Rate Limited

### Tooltips

**Tooltip Container**
- Background: #1F2937 (dark gray)
- Text: White, 11px
- Padding: 6px 8px
- Border radius: 4px
- Max-width: 200px
- Arrow: 6px triangle pointing to origin element
- Animation: opacity 0 → 1 (100ms on hover)
- Z-index: 1000 (above graph)

### Tables

**Table Header**
- Background: #F9FAFB (off-white)
- Text: #1F2937 (dark), 12px, bold, uppercase
- Border-bottom: 1px solid #E5E7EB
- Padding: 12px 16px

**Table Row**
- Background: #FFFFFF
- Text: #1F2937, 14px
- Padding: 12px 16px
- Border-bottom: 1px solid #F3F4F6
- Hover: Background #F9FAFB

**Table Data Cell**
- Max-width determined by column; text truncates with ellipsis if needed
- Clickable cells: Cursor pointer, hover background

---

## 5. GRAPH NODE & EDGE STYLING (SVG/Canvas)

### Node (Entity) Base Style

**Default State**
- Shape: Determined by entity type (circle, house, pentagon, etc.)
- Border: 2px solid (entity type color)
- Fill: White (#FFFFFF)
- Size: 20–60px (based on degree centrality)
- Label: Centered, white text, 12px bold

**Hover State**
- Border: 4px solid (entity type color)
- Box-shadow: 0 0 12px (entity type color, 30% opacity)
- Cursor: pointer
- Label visible on all screens

**Selected State**
- Border: 4px solid #FFD700 (gold)
- Box-shadow: 0 0 16px (gold, 50% opacity)
- Label: Increased font-size or background highlight

**Faded State (Timeline)**
- Opacity: 0.4
- Color: Desaturated (−50% saturation)
- Cursor: not-allowed

**Pinned State**
- Icon: Small lock symbol (top-right corner of node)
- Border: Dashed instead of solid (optional visual indicator)

### Edge (Relationship) Base Style

**Default State**
- Stroke width: 0.5–3px (based on confidence)
- Stroke color: Determined by relationship type
- Stroke linecap: round
- Arrow: Arrowhead (7px) on target node side
- Label: Relationship type, 11px, background white box

**Hover State**
- Stroke width: +1px
- Stroke opacity: 1 (if faded, become opaque)
- Box-shadow on label: 0 2px 4px rgba(0, 0, 0, 0.1)

**Faded State (Timeline)**
- Opacity: 0.2
- Stroke: Dashed (instead of solid)
- Label: Hidden

**Bidirectional State**
- Arrows on both ends of edge (if relationship is symmetric)
- Or: Double-sided arrowhead

### Node Size Mapping
```
Node size = (20 + (degree / max_degree) * 40) pixels
Min: 20px (leaf nodes)
Max: 60px (hub nodes)
```

### Color Opacity Rules
- **Full opacity (1.0):** Normal entities, high confidence
- **Medium opacity (0.8):** Lower confidence (<70%)
- **Low opacity (0.4):** Faded (timeline), hidden
- **Desaturated:** Timeline or filtered state (−50% HSL saturation)

---

## 6. ANIMATIONS & TRANSITIONS

### Timing Functions
- **Fast (100–200ms):** UI feedback (hover, focus, select)
- **Standard (200–300ms):** Panel slide-in/out, modal appear
- **Slow (300–500ms):** Full-page transitions, graph layout

### Easing Curves
- **Ease-in-out:** `cubic-bezier(0.4, 0, 0.2, 1)` (standard transitions)
- **Ease-out:** `cubic-bezier(0, 0, 0.2, 1)` (slide-in panels)
- **Ease-in:** `cubic-bezier(0.4, 0, 1, 1)` (slide-out panels)

### Animation Patterns

**Fade-in (entrance)**
```css
animation: fadeIn 200ms ease-out;
@keyframes fadeIn {
  from { opacity: 0; }
  to { opacity: 1; }
}
```

**Slide-in from right (panels)**
```css
animation: slideInRight 300ms ease-out;
@keyframes slideInRight {
  from { transform: translateX(100%); opacity: 0; }
  to { transform: translateX(0); opacity: 1; }
}
```

**Scale-in (modal, popover)**
```css
animation: scaleIn 200ms ease-out;
@keyframes scaleIn {
  from { transform: scale(0.95); opacity: 0; }
  to { transform: scale(1); opacity: 1; }
}
```

**Bounce (attention)**
```css
animation: bounce 400ms ease-in-out;
@keyframes bounce {
  0%, 100% { transform: translateY(0); }
  50% { transform: translateY(-10px); }
}
```

### Graph Physics Animation
- Force simulation updates at 60 FPS (16.67ms per frame)
- Node movement: Smooth interpolation over 2–3 frames
- Initial layout: Animate from center to final position over 1s

---

## 7. SHADOWS & ELEVATION

### Shadow Tokens
```
shadow-sm: 0 1px 2px 0 rgba(0, 0, 0, 0.05)
shadow-md: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06)
shadow-lg: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05)
shadow-xl: 0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04)
shadow-2xl: 0 25px 50px -12px rgba(0, 0, 0, 0.25)
```

### Elevation Rules
- **Cards, buttons:** shadow-md
- **Modals, dropdowns:** shadow-lg
- **Tooltips, popovers:** shadow-md
- **Panels (sidebars, detail):** shadow-lg or shadow-xl (depends on depth)

---

## 8. GRAPH NODE ICONS

Each entity type should have a distinct, recognizable icon centered in the node (or top-left corner, TBD by designer).

### Icon Specifications

| Entity Type | Icon | Icon Source | Size | Color |
|---|---|---|---|---|
| Person | Head silhouette | Feather Icons: user | 16px | White |
| Address | House | Feather Icons: home | 18px | White |
| Business | Building | Feather Icons: briefcase or building-2 | 18px | White |
| Vehicle | Car | Feather Icons: truck | 16px | White |
| Court Case | Gavel | Feather Icons: gavel (custom) | 16px | White |
| Property Record | Document | Feather Icons: file-text | 16px | White |
| Legal Entity | Briefcase | Feather Icons: briefcase | 18px | White |
| Phone | Phone | Feather Icons: phone | 16px | White |
| Email | Envelope | Feather Icons: mail | 16px | White |
| Organization | Building (institution) | Feather Icons: shield or building | 18px | White |

**Icon Implementation:**
- Source: Feather Icons (free, open-source)
- Fallback: Custom SVG icons
- Rendering: SVG inline in graph layer (above node background)
- Color: Always white (#FFFFFF) for contrast against colored node background

---

## 9. RESPONSIVE DESIGN (MVP: Desktop-Only)

### Mobile / Tablet (Future Feature)

**Breakpoints:**
```
sm: 640px
md: 768px
lg: 1024px
xl: 1280px
2xl: 1536px
```

**Responsive Adjustments (when mobile support added):**
- **Graph canvas:** Full width, height adjusts
- **Detail panel:** Bottom sheet (iOS) or overlay (Android)
- **Dashboard cards:** Stack vertically (1 column < md, 2 columns ≥ md)
- **Toolbar:** Hamburger menu for controls (< lg)
- **Font sizes:** Slightly larger on mobile (16px min for inputs, to prevent auto-zoom on iOS)

---

## 10. ACCESSIBILITY & CONTRAST

### WCAG 2.1 AA Standards

**Color Contrast Ratios (minimum 4.5:1 for normal text, 3:1 for large text):**
- Ensure all text meets contrast requirements
- Test with tools: WebAIM Contrast Checker, Axe DevTools

**Button / Link Text:**
- Blue (#3B82F6) on white: 4.48:1 ✓
- Dark gray (#1F2937) on white: 18:1 ✓
- Red (#EF4444) on white: 3.99:1 ✗ (needs adjustment for small text)

### Focus States
- All interactive elements must have visible focus indicator
- Focus ring: 2–3px outline or box-shadow
- Color: #3B82F6 (blue) or contrasting color

### Keyboard Navigation
- Tab order: Logical left-to-right, top-to-bottom
- Focusable elements: Buttons, inputs, links, graph nodes
- Skip navigation: Skip to main content link (optional)

### Screen Reader Support
- Semantic HTML: Use `<button>`, `<label>`, `<nav>`, etc.
- ARIA labels: aria-label, aria-labelledby for complex widgets
- Live regions: aria-live for status updates (e.g., "Source completed")
- Image alt text: All icons have alt text or aria-label

### Motion & Animation
- Respect prefers-reduced-motion: Disable animations for users with vestibular disorders
```css
@media (prefers-reduced-motion: reduce) {
  * { animation: none !important; transition: none !important; }
}
```

---

## 11. DARK MODE (FUTURE FEATURE)

If dark mode is added post-MVP, use these color substitutions:

### Dark Mode Palette
- **Background:** #0F172A (very dark blue)
- **Card background:** #1E293B (dark blue-gray)
- **Text:** #E2E8F0 (light gray)
- **Borders:** #334155 (muted blue-gray)
- **Blue (primary):** #60A5FA (lighter blue for contrast)
- **Green:** #4ADE80 (lighter green)
- **Red:** #F87171 (lighter red)

---

## 12. ICON LIBRARY & ASSETS

### Icon Sources
1. **Feather Icons** (default): Open-source, MIT license, simple line icons
2. **Heroicons** (alternative): Tailwind's official icon library
3. **Custom SVGs**: For specialized icons (gavel, house, etc.)

### Icon Usage Rules
- **Size:** 16–24px depending on context
- **Stroke width:** 2px (matches Feather default)
- **Color:** Inherit text color, or explicitly white/dark per context
- **Accessibility:** Icon buttons must have aria-label

---

## 13. DATA VISUALIZATION (NON-GRAPH)

### Charts & Graphs (Dashboard Cards)

**Entity Type Breakdown (Pie Chart or Bar Chart):**
- Colors: Use entity type colors
- Labels: Entity type name + count
- Legend: Below chart, small text

**Relationship Type Breakdown (Horizontal Bar Chart):**
- Colors: Relationship type colors
- Labels: Relationship type + percentage or count
- Sorted by frequency (descending)

**Timeline (Vertical Bar Chart):**
- X-axis: Date (monthly or weekly buckets)
- Y-axis: Count of entities discovered
- Color: Blue (#3B82F6)
- Hover: Tooltip with exact count + date range

---

## 14. DARK MODE & THEME TOGGLE (FUTURE)

```css
:root {
  --color-bg: #FFFFFF;
  --color-surface: #F9FAFB;
  --color-text: #1F2937;
  --color-border: #E5E7EB;
}

[data-theme="dark"] {
  --color-bg: #0F172A;
  --color-surface: #1E293B;
  --color-text: #E2E8F0;
  --color-border: #334155;
}
```

---

## 15. IMPLEMENTATION CHECKLIST

### Frontend Developer Checklist
- [ ] Create Tailwind CSS config with custom colors
- [ ] Set up shadcn/ui component library
- [ ] Define reusable component library (Button, Card, Input, Badge, etc.)
- [ ] Implement graph rendering with Neovis.js + custom node/edge styling
- [ ] Create address autocomplete component with debouncing
- [ ] Build dashboard cards with responsive grid
- [ ] Implement entity detail panel with tabs
- [ ] Add graph interactions (click, right-click, drag, zoom, pan)
- [ ] Set up animations (Framer Motion or CSS)
- [ ] Test accessibility (WCAG 2.1 AA)
- [ ] Test performance (graph rendering time, FPS)
- [ ] Test on Chrome, Firefox, Safari, Edge

### Design QA Checklist
- [ ] All colors match spec
- [ ] All fonts match spec
- [ ] All spacing follows 8px grid
- [ ] All shadows match elevation rules
- [ ] All animations follow timing curves
- [ ] All interactive states (hover, focus, active) implemented
- [ ] All buttons are min 44px × 44px (touch target)
- [ ] All text readable on all backgrounds
- [ ] All icons are properly aligned and sized

---

**End of Design System**

*This document is the source of truth for visual design during frontend implementation.*
*Any design decisions not specified here should reference PRODUCT_SPEC.md or be escalated to the design team.*
