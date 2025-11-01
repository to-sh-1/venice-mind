# AI Assistant Guidelines

## Primary Directive: Do Not Change Code Without Explicit Request

### Strict Rules for AI Assistants

1. **READ-ONLY BY DEFAULT**

   - Treat all code as read-only unless explicitly asked to modify
   - Only make changes when the user explicitly requests them
   - Ask for confirmation before making any non-trivial changes

2. **PRESERVE EXISTING PATTERNS**

   - Follow existing code style and conventions
   - Don't refactor code "to be better" unless asked
   - Don't change naming conventions
   - Don't reorganize code structure

3. **MINIMAL CHANGES ONLY**

   - Make only the specific changes requested
   - Don't add unrelated improvements
   - Don't fix "issues" that weren't mentioned
   - Don't optimize code unless asked

4. **EXPLICIT PERMISSION REQUIRED FOR:**
   - Adding new functions or features
   - Changing function signatures
   - Modifying state variables
   - Refactoring code structure
   - Changing variable or function names
   - Adding or removing imports
   - Changing error messages or event definitions

## When User Makes a Request

### Before Making Changes:

1. **Confirm what you understand** they want changed
2. **Show what will change** if it's not obvious
3. **Ask if they want** any related improvements
4. **Respect existing patterns** in the codebase

### During Changes:

1. **Make only requested changes**
2. **Preserve formatting and style**
3. **Keep existing comments** unless they become incorrect
4. **Don't add "helpful" features** they didn't ask for

### After Changes:

1. **Explain what changed** clearly
2. **Note any side effects** or implications
3. **Suggest testing** if significant changes were made
4. **Don't make follow-up "improvements"** unless asked

## Communication Guidelines

### What to Say:

- ✅ "I'll make that change"
- ✅ "Here's the specific change you requested"
- ✅ "Should I also update [related thing]?"
- ✅ "This change will affect [X], is that okay?"

### What NOT to Say:

- ❌ "I've also improved..."
- ❌ "While I was at it, I..."
- ❌ "I noticed you could also..."
- ❌ "Let me refactor this while we're here..."

## Code Review Principles

### When Reviewing Code:

- **Point out issues** but don't fix them unless asked
- **Suggest improvements** but don't implement them
- **Explain problems** without changing code
- **Ask permission** before making any modifications

### When Explaining Code:

- **Focus on what it does**, not what it could do better
- **Explain the existing logic**, not alternative approaches
- **Clarify questions**, don't rewrite the code
- **Use examples** from the existing codebase

## Edge Cases

### If Code Has Bugs:

1. **Point out the bug** clearly
2. **Explain why it's a problem**
3. **Ask if they want you to fix it**
4. **Don't fix it automatically** unless it's clearly causing an error they're asking about

### If Code Could Be Improved:

1. **Mention the opportunity** if relevant to the discussion
2. **Don't implement the improvement** unless asked
3. **Wait for explicit request** before optimizing

### If Code Doesn't Follow Best Practices:

1. **Note the deviation** if it's relevant
2. **Explain why it matters** if there's a security/gas issue
3. **Don't "fix" it** unless explicitly requested or it's clearly a mistake

## Project-Specific Guidelines

### For This Project (Venice Mind Burn):

- **Don't change** the factory/mind pattern
- **Don't modify** ownership transfer logic unless asked
- **Don't add** new features to contracts
- **Don't change** the burn mechanism (address(1))
- **Don't refactor** existing tests unless requested
- **Preserve** the minimal proxy clone pattern
- **Maintain** existing event structures
- **Keep** existing error definitions

## Examples of Good vs Bad Behavior

### ❌ BAD:

User: "Add a function to get total burned"
AI: "I've added the function and also optimized the burn function, refactored the storage layout, and added some helper functions."

### ✅ GOOD:

User: "Add a function to get total burned"
AI: "I've added the `getTotalBurned()` function as requested."

### ❌ BAD:

User: "Fix the typo in line 42"
AI: [Fixes typo and also reformats entire file, adds comments, changes variable names]

### ✅ GOOD:

User: "Fix the typo in line 42"
AI: [Fixes only the typo on line 42]

### ❌ BAD:

AI: "I noticed your code doesn't use custom errors. Let me fix that for you."

### ✅ GOOD:

AI: "Your code uses require strings. Custom errors would save gas, but I'll leave it as-is unless you want me to change it."
