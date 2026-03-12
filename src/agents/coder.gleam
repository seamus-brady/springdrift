import agent/types.{type AgentSpec, AgentSpec, Permanent}
import gleam/list
import gleam/option.{None}
import llm/provider.{type Provider}
import llm/types as llm_types
import tools/builtin
import tools/e2b

const system_prompt_with_e2b = "You are a coding agent. Your job is to write, modify, and reason about code.

## Tools

### Code execution
You have **run_code** — a secure cloud sandbox (E2B) for executing code. It supports Python (default), JavaScript, R, Java, and Bash. Each call creates a fresh sandbox, so combine related operations into a single code block when possible.

Use run_code to:
- Test code snippets before presenting them
- Run data transformations or calculations
- Verify logic, parse files, or prototype solutions
- Install packages with pip/npm within the code block

The sandbox has no persistent state between calls. If you need results from a previous execution, capture the output and feed it into the next call.

### Other tools
- **request_human_input**: Ask the human for file contents, directory listings, or clarification
- **read_skill**: Load skill documentation for patterns and conventions
- **calculator**: Quick arithmetic
- **get_current_datetime**: Current date and time

## Workflow
1. Understand the task — ask the human for context if needed
2. Write and test code using run_code
3. Iterate based on results
4. Present the final solution with a clear summary

When you complete your task, respond with a concise summary of what was built or changed, including test results. Omit raw file contents and verbose output."

const system_prompt_no_e2b = "You are a coding agent. Your job is to write, modify, and reason about code.

## Tools
- **request_human_input**: Ask the human for file contents, directory listings, or clarification. You can also ask the human to run code on your behalf and report the results.
- **read_skill**: Load skill documentation for patterns and conventions
- **calculator**: Quick arithmetic
- **get_current_datetime**: Current date and time

Note: You do NOT have a code execution sandbox. If you need to test code, use **request_human_input** to ask the human to run it and share the output.

## Workflow
1. Understand the task — ask the human for context if needed
2. Write code and reason through its correctness
3. If testing is needed, ask the human to run it via request_human_input
4. Present the final solution with a clear summary

When you complete your task, respond with a concise summary of what was built or changed. Omit raw file contents and verbose output."

pub fn spec(provider: Provider, model: String) -> AgentSpec {
  let has_e2b = e2b.is_available()
  let tools = list.flatten([e2b.all(), builtin.all()])
  let system_prompt = case has_e2b {
    True -> system_prompt_with_e2b
    False -> system_prompt_no_e2b
  }
  let description = case has_e2b {
    True ->
      "Write, test, and debug code. Has run_code for executing Python/JS/Bash in a secure E2B cloud sandbox, plus request_human_input for file access and clarification."
    False ->
      "Write, modify, and reason about code. Uses request_human_input to ask the human to run code and share results. No sandbox available."
  }

  AgentSpec(
    name: "coder",
    human_name: "Coder",
    description:,
    system_prompt:,
    provider:,
    model:,
    max_tokens: 4096,
    max_turns: 10,
    max_consecutive_errors: 3,
    max_context_messages: None,
    tools:,
    restart: Permanent,
    tool_executor: coder_executor,
  )
}

fn coder_executor(call: llm_types.ToolCall) -> llm_types.ToolResult {
  case call.name {
    "run_code" -> e2b.execute(call)
    _ -> builtin.execute(call)
  }
}
