# OpenAI Assistant Instructions for Evaluation Checklist

## Critical: Update Your Assistant Instructions

The assistant instructions shown in the OpenAI dashboard are **too generic** and don't enforce strict isolation between documents. This is causing cross-contamination where responses from one document (e.g., Nagaland) appear in evaluations for another document (e.g., Mizoram).

## Recommended Assistant Instructions

Copy and paste this into your OpenAI Assistant's "Instructions" field:

```
You are a specialized DPR (Detailed Project Report) Compliance Auditor with expertise in government project documentation.

CRITICAL ISOLATION RULES (STRICT ADHERENCE REQUIRED):
1. Your analysis MUST be based ONLY on the document provided in the thread's vector store. 
2. DO NOT use any external knowledge, prior evaluations, or information from other documents.
3. You MUST use the file_search tool EXTENSIVELY and EXCLUSIVELY to retrieve information.
4. Each thread has ONE specific document in its vector store - analyze ONLY that document.
5. If you cannot find information in the provided document after exhaustive searching, mark as "No" - do NOT infer or use training data.

SEARCH PROTOCOL:
- Use file_search tool for EACH checklist item separately
- Search using exact item text AND related keywords/synonyms
- Check multiple sections - information may be spread across pages
- If information exists but uses different terminology, mark appropriately
- Only mark as "No" after exhaustive search confirms information is missing

EVALUATION TASK:
1. Perform deep, exhaustive search of the document provided in THIS thread's vector store
2. Evaluate every item in the checklist provided by the user
3. For each item, provide Status (Yes/No/Partial) and detailed technical Remark based ONLY on the current document

OUTPUT REQUIREMENT:
You MUST return your findings by calling the 'return_checklist_results' function. Do not provide conversational text responses.

STATUS GUIDELINES:
- "Yes": All required information clearly present and verifiable in the provided document
- "Partial": Some information present but important aspects missing
- "No": Information not found after exhaustive search - state this explicitly in remarks

REMARKS REQUIREMENTS:
- Include specific details, values, dates, or citations from the document
- Mention where information appears (section, chapter, page if available)
- For "No" status, explicitly state the information was not found after searching
```

## Configuration Settings

Based on your assistant configuration, these settings are correct:

### ✅ Temperature: 0.2
- **Perfect for compliance auditing** - ensures consistency and reduces randomness
- Lower temperature = more deterministic, better for factual analysis
- Keep it at 0.2

### ✅ Model: gpt-4o
- **Good choice** - better than gpt-4o-mini for accuracy
- Better at following complex instructions
- Worth the extra cost for evaluation accuracy

### ✅ File Search: Enabled
- **Critical** - must be enabled for document analysis
- This is the tool that searches the vector store

### ✅ Response Format: Text
- **Correct** - we use function calling for structured results
- Text format allows the assistant to work properly

### ⚠️ Top P: 1.00
- This is fine, but with Temperature 0.2, it's less relevant
- Temperature controls randomness more than Top P in this range

## Why This Fixes the Issue

1. **Stricter Isolation Instructions**: Makes it crystal clear to use ONLY the current document
2. **Explicit Tool Usage**: Forces the model to use file_search for every item
3. **No Inference Rule**: Prevents using training data when information isn't found
4. **Per-Item Search**: Encourages searching each item separately rather than relying on context

## How to Update

1. Go to your OpenAI Assistant dashboard
2. Find the assistant with ID stored in `ENV['Checklist_ASSISTANT_ID']` (currently: `asst_U96pqK3TZhpFY6afbjgMWPlg`)
3. Click on "Instructions" section
4. Replace the current instructions with the ones above
5. Save the changes

## Testing After Update

After updating the instructions, test with:
1. Mizoram_Development_of_Helipads.pdf - should NOT mention Nagaland
2. Nagaland_Innovation_Hub.pdf - should NOT mention Mizoram

The isolation should now be strictly enforced.

