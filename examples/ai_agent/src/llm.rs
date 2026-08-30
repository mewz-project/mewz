use serde::{Deserialize, Serialize};
use serde_json::Value;

const OPENAI_API_URL: &str = "https://api.openai.com/v1/chat/completions";
const MODEL: &str = "gpt-4o-mini";

const SYSTEM_PROMPT: &str = "\
You are a helpful AI agent running on Mewz. \
Use the available tools to gather information and complete the user's task. \
Think step by step. When you have enough information, reply with the final answer \
directly without calling any more tools.";

pub struct OpenAiClient {
    api_key: String,
    http: reqwest::Client,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCall>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub function: FunctionCall,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionCall {
    pub name: String,
    pub arguments: String,
}

#[derive(Debug, Deserialize)]
struct ChatCompletionResponse {
    choices: Vec<ChatCompletionChoice>,
}

#[derive(Debug, Deserialize)]
struct ChatCompletionChoice {
    message: ChatMessage,
}

#[derive(Debug, Clone)]
pub struct ToolInvocation {
    pub thought: String,
    pub action: String,
    pub args: String,
}

impl OpenAiClient {
    pub fn new(api_key: &str) -> Result<Self, String> {
        if api_key.trim().is_empty() {
            return Err("OpenAI API key must not be empty".to_string());
        }

        let http = reqwest::Client::builder()
            .build()
            .map_err(|err| format!("failed to create HTTP client: {err}"))?;

        Ok(Self {
            api_key: api_key.to_string(),
            http,
        })
    }

    pub async fn next_step(
        &self,
        task: &str,
        messages: &mut Vec<ChatMessage>,
    ) -> Result<StepOutcome, String> {
        if messages.is_empty() {
            messages.push(ChatMessage {
                role: "system".to_string(),
                content: Some(SYSTEM_PROMPT.to_string()),
                tool_calls: None,
                tool_call_id: None,
            });
            messages.push(ChatMessage {
                role: "user".to_string(),
                content: Some(task.to_string()),
                tool_calls: None,
                tool_call_id: None,
            });
        }

        let body = serde_json::json!({
            "model": MODEL,
            "messages": messages,
            "tools": tool_definitions(),
        });

        let response = self
            .http
            .post(OPENAI_API_URL)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|err| format!("OpenAI request failed: {err}"))?;

        let status = response.status();
        let response_body = response
            .text()
            .await
            .map_err(|err| format!("failed to read OpenAI response: {err}"))?;

        if !status.is_success() {
            return Err(format!("OpenAI API error ({status}): {response_body}"));
        }

        let completion: ChatCompletionResponse = serde_json::from_str(&response_body)
            .map_err(|err| format!("failed to parse OpenAI response: {err}: {response_body}"))?;

        let message = completion
            .choices
            .into_iter()
            .next()
            .map(|choice| choice.message)
            .ok_or_else(|| "OpenAI returned no choices".to_string())?;

        if let Some(tool_calls) = message.tool_calls.clone() {
            let invocation = parse_tool_invocation(&message, &tool_calls)?;
            messages.push(message);
            return Ok(StepOutcome::Tool(invocation));
        }

        let answer = message
            .content
            .clone()
            .filter(|content| !content.trim().is_empty())
            .ok_or_else(|| "OpenAI returned an empty final answer".to_string())?;

        Ok(StepOutcome::Answer(answer))
    }

    pub fn push_tool_result(
        messages: &mut Vec<ChatMessage>,
        tool_call_id: &str,
        observation: &str,
    ) {
        messages.push(ChatMessage {
            role: "tool".to_string(),
            content: Some(observation.to_string()),
            tool_calls: None,
            tool_call_id: Some(tool_call_id.to_string()),
        });
    }
}

#[derive(Debug, Clone)]
pub enum StepOutcome {
    Tool(ToolInvocation),
    Answer(String),
}

fn tool_definitions() -> Value {
    serde_json::json!([
        {
            "type": "function",
            "function": {
                "name": "calculator",
                "description": "Evaluate a basic arithmetic expression (+, -, *, /, parentheses).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "expression": {
                            "type": "string",
                            "description": "Arithmetic expression such as 2+2 or (10+5)*2"
                        }
                    },
                    "required": ["expression"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "get_time",
                "description": "Return the current UTC time.",
                "parameters": {
                    "type": "object",
                    "properties": {}
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read a file from the bundled read-only filesystem.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "Relative file path such as README.md"
                        }
                    },
                    "required": ["path"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "echo",
                "description": "Echo the given text back unchanged.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "text": {
                            "type": "string",
                            "description": "Text to echo"
                        }
                    },
                    "required": ["text"]
                }
            }
        }
    ])
}

fn parse_tool_invocation(
    message: &ChatMessage,
    tool_calls: &[ToolCall],
) -> Result<ToolInvocation, String> {
    let tool_call = tool_calls
        .first()
        .ok_or_else(|| "OpenAI returned tool_calls without entries".to_string())?;

    if tool_calls.len() > 1 {
        return Err("expected at most one tool call per step".to_string());
    }

    let args = parse_tool_args(&tool_call.function.name, &tool_call.function.arguments)?;

    Ok(ToolInvocation {
        thought: message
            .content
            .clone()
            .unwrap_or_else(|| format!("call `{}`", tool_call.function.name)),
        action: tool_call.function.name.clone(),
        args,
    })
}

fn parse_tool_args(name: &str, raw_args: &str) -> Result<String, String> {
    let parsed: Value = serde_json::from_str(raw_args)
        .map_err(|err| format!("invalid tool arguments for `{name}`: {err}"))?;

    match name {
        "calculator" => parsed
            .get("expression")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .ok_or_else(|| format!("calculator requires a non-empty `expression`")),
        "get_time" => Ok(String::new()),
        "read_file" => parsed
            .get("path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .ok_or_else(|| format!("read_file requires a non-empty `path`")),
        "echo" => parsed
            .get("text")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| format!("echo requires `text`")),
        other => Err(format!("unknown tool from OpenAI: {other}")),
    }
}
