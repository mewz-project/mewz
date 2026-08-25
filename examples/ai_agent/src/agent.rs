use crate::llm::{compose_answer, decide_next};
use crate::tools;

const MAX_STEPS: usize = 5;

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

pub fn run(task: &str) -> AgentResponse {
    let mut history = Vec::new();

    for step_number in 1..=MAX_STEPS {
        let Some(plan) = decide_next(task, &history) else {
            break;
        };

        let observation = match tools::execute(&plan.action, &plan.args) {
            Ok(value) => value,
            Err(err) => format!("error: {err}"),
        };

        history.push(AgentStep {
            step: step_number as u32,
            thought: plan.thought,
            action: plan.action,
            args: plan.args,
            observation,
        });
    }

    let answer = compose_answer(task, &history);

    AgentResponse {
        task: task.to_string(),
        mode: "mock-react",
        steps: history,
        answer,
    }
}
