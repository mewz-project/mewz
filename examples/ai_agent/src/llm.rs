use crate::agent::AgentStep;

#[derive(Debug, Clone)]
pub struct PlannedAction {
    pub thought: String,
    pub action: String,
    pub args: String,
}

pub fn decide_next(task: &str, history: &[AgentStep]) -> Option<PlannedAction> {
    let task_lower = task.to_lowercase();

    if task.contains('倍') && used_tool(history, "get_time") && used_tool(history, "calculator") {
        return None;
    }

    if needs_time(&task_lower) && !used_tool(history, "get_time") {
        return Some(PlannedAction {
            thought: "タスクに時刻が関係するので、まず現在時刻を取得する".to_string(),
            action: "get_time".to_string(),
            args: String::new(),
        });
    }

    if let Some(expr) = follow_up_calculator(task, history) {
        return Some(PlannedAction {
            thought: "前の観測結果を使って計算する".to_string(),
            action: "calculator".to_string(),
            args: expr,
        });
    }

    if let Some(expr) = direct_calculator(task) {
        if !already_calculated(history, &expr) {
            return Some(PlannedAction {
                thought: "数式を計算する".to_string(),
                action: "calculator".to_string(),
                args: expr,
            });
        }
    }

    if needs_read_file(&task_lower) && !used_tool(history, "read_file") {
        let path = extract_file_path(task).unwrap_or_else(|| "README.md".to_string());
        return Some(PlannedAction {
            thought: format!("`{path}` を読んで内容を確認する"),
            action: "read_file".to_string(),
            args: path,
        });
    }

    if history.is_empty() {
        return Some(PlannedAction {
            thought: "そのまま入力内容を返す".to_string(),
            action: "echo".to_string(),
            args: task.to_string(),
        });
    }

    None
}

fn needs_time(task: &str) -> bool {
    task.contains("時刻")
        || task.contains("時間")
        || task.contains("time")
        || task.contains("now")
        || (task.contains("分") && task.contains("倍"))
}

fn needs_read_file(task: &str) -> bool {
    task.contains("readme")
        || task.contains("ファイル")
        || task.contains("file")
        || task.contains("読んで")
        || task.contains("read")
        || task.contains("ドキュメント")
        || task.contains("document")
}

fn used_tool(history: &[AgentStep], action: &str) -> bool {
    history.iter().any(|step| step.action == action)
}

fn already_calculated(history: &[AgentStep], expr: &str) -> bool {
    history
        .iter()
        .any(|step| step.action == "calculator" && step.args == expr)
}

fn direct_calculator(task: &str) -> Option<String> {
    if let Some(start) = task.find('`') {
        let rest = &task[start + 1..];
        if let Some(end) = rest.find('`') {
            let expr = rest[..end].trim();
            if looks_like_expression(expr) {
                return Some(expr.to_string());
            }
        }
    }

    let mut expr = String::new();
    let mut has_digit = false;
    for ch in task.chars() {
        if ch.is_ascii_digit() || "+-*/()".contains(ch) {
            expr.push(ch);
            if ch.is_ascii_digit() {
                has_digit = true;
            }
        } else if !expr.is_empty() && has_digit {
            break;
        }
    }

    if has_digit && looks_like_arithmetic(expr.trim()) {
        return Some(expr.trim().to_string());
    }

    if task.contains("計算") {
        for token in task.split_whitespace() {
            if looks_like_expression(token) {
                return Some(token.to_string());
            }
        }
    }

    None
}

fn follow_up_calculator(task: &str, history: &[AgentStep]) -> Option<String> {
    if !task.contains('倍') {
        return None;
    }

    let last = history.last()?;
    if last.action != "get_time" {
        return None;
    }

    let minutes = parse_minutes(&last.observation)?;
    let multiplier = parse_multiplier(task).unwrap_or(2);
    Some(format!("{minutes}*{multiplier}"))
}

fn parse_minutes(observation: &str) -> Option<i64> {
    let time_part = observation.split_whitespace().next()?;
    let mut parts = time_part.split(':');
    let _hours = parts.next()?;
    let minutes = parts.next()?.parse().ok()?;
    Some(minutes)
}

fn parse_multiplier(task: &str) -> Option<i64> {
    for token in task.split_whitespace() {
        if let Some(num) = token.strip_suffix('倍') {
            if let Ok(value) = num.parse::<i64>() {
                return Some(value);
            }
        }
    }

    for token in task.split_whitespace() {
        if token.ends_with('倍') {
            let digits: String = token.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(value) = digits.parse::<i64>() {
                return Some(value);
            }
        }
    }

    None
}

fn extract_file_path(task: &str) -> Option<String> {
    for token in task.split_whitespace() {
        if token.contains('.') && !token.contains("..") {
            return Some(token.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '.' && c != '_').to_string());
        }
    }
    None
}

fn looks_like_expression(expr: &str) -> bool {
    !expr.is_empty()
        && expr
            .chars()
            .all(|c| c.is_ascii_digit() || "+-*/()".contains(c) || c.is_ascii_whitespace())
        && expr.chars().any(|c| c.is_ascii_digit())
}

fn looks_like_arithmetic(expr: &str) -> bool {
    looks_like_expression(expr) && expr.chars().any(|c| "+-*/".contains(c))
}

pub fn compose_answer(task: &str, history: &[AgentStep]) -> String {
    if let Some(last) = history.last() {
        if task.contains('倍') && last.action == "calculator" {
            return format!("答えは {} です。", last.observation);
        }

        if last.action == "read_file" {
            let preview: String = last.observation.chars().take(200).collect();
            let suffix = if last.observation.chars().count() > 200 {
                "..."
            } else {
                ""
            };
            return format!("ファイル内容:\n{preview}{suffix}");
        }

        if last.action == "get_time" && history.len() == 1 {
            return format!("現在時刻は {} です。", last.observation);
        }

        if last.action == "calculator" {
            return format!("計算結果は {} です。", last.observation);
        }

        if last.action == "echo" {
            return format!("{}", last.observation);
        }
    }

    "タスクを完了しました。".to_string()
}
