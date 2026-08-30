use crate::llm::{OpenAiClient, StepOutcome};
use crate::tools;

const MAX_STEPS: usize = 8;

#[derive(Debug, Clone, serde::Serialize)]
pub struct AgentStep {
    pub step: u32,
    pub thought: String,
    pub action: String,
    pub args: String,
    pub observation: String,
}

#[derive(Debug, serde::Serialize)]
pub struct AgentResponse {
    pub task: String,
    pub mode: &'static str,
    pub steps: Vec<AgentStep>,
    pub answer: String,
}

pub async fn run(api_key: &str, task: &str) -> Result<AgentResponse, String> {
    let client = OpenAiClient::new(api_key)?;
    let mut messages = Vec::new();
    let mut steps = Vec::new();

    for step_number in 1..=MAX_STEPS {
        match client.next_step(task, &mut messages).await? {
            StepOutcome::Answer(answer) => {
                return Ok(AgentResponse {
                    task: task.to_string(),
                    mode: "openai-react",
                    steps,
                    answer,
                });
            }
            StepOutcome::Tool(plan) => {
                let observation = match tools::execute(&plan.action, &plan.args) {
                    Ok(value) => value,
                    Err(err) => format!("error: {err}"),
                };

                let tool_call_id = messages
                    .last()
                    .and_then(|message| message.tool_calls.as_ref())
                    .and_then(|tool_calls| tool_calls.first())
                    .map(|tool_call| tool_call.id.clone());

                if let Some(tool_call_id) = tool_call_id {
                    OpenAiClient::push_tool_result(&mut messages, &tool_call_id, &observation);
                }

                steps.push(AgentStep {
                    step: step_number as u32,
                    thought: plan.thought,
                    action: plan.action,
                    args: plan.args,
                    observation,
                });
            }
        }
    }

    Ok(AgentResponse {
        task: task.to_string(),
        mode: "openai-react",
        steps,
        answer: "Reached the maximum number of agent steps without a final answer.".to_string(),
    })
}
