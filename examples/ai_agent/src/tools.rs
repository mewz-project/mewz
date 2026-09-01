use std::fs;

pub fn execute(name: &str, args: &str) -> Result<String, String> {
    match name {
        "calculator" => calculator(args),
        "get_time" => Ok(get_time()),
        "read_file" => read_file(args),
        "echo" => Ok(if args.is_empty() {
            "(empty)".to_string()
        } else {
            args.to_string()
        }),
        _ => Err(format!("unknown tool: {name}")),
    }
}

fn calculator(expr: &str) -> Result<String, String> {
    let value = eval_expr(expr.trim())?;
    Ok(value.to_string())
}

fn get_time() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let day_secs = secs % 86_400;
    let hours = day_secs / 3_600;
    let minutes = (day_secs % 3_600) / 60;
    let seconds = day_secs % 60;

    format!("{hours:02}:{minutes:02}:{seconds:02} UTC (epoch={secs})")
}

fn read_file(path: &str) -> Result<String, String> {
    let path = path.trim();
    if path.is_empty() {
        return Err("file path is required".to_string());
    }
    if path.contains("..") {
        return Err("path traversal is not allowed".to_string());
    }

    match fs::read_to_string(path) {
        Ok(content) => Ok(content),
        Err(e) => Err(format!("failed to read {path}: {e}")),
    }
}

fn eval_expr(input: &str) -> Result<i64, String> {
    let tokens = tokenize(input)?;
    let (value, rest) = parse_expr(&tokens, 0)?;
    if rest != tokens.len() {
        return Err(format!("unexpected trailing input in `{input}`"));
    }
    Ok(value)
}

fn tokenize(input: &str) -> Result<Vec<Token>, String> {
    let mut tokens = Vec::new();
    let mut chars = input.chars().peekable();

    while let Some(ch) = chars.peek().copied() {
        if ch.is_ascii_whitespace() {
            chars.next();
            continue;
        }

        if ch.is_ascii_digit() {
            let mut digits = String::new();
            while let Some(next) = chars.peek().copied() {
                if next.is_ascii_digit() {
                    digits.push(next);
                    chars.next();
                } else {
                    break;
                }
            }
            tokens.push(Token::Number(
                digits
                    .parse::<i64>()
                    .map_err(|_| format!("invalid number in `{input}`"))?,
            ));
            continue;
        }

        if "+-*/".contains(ch) {
            tokens.push(Token::Op(ch));
            chars.next();
            continue;
        }

        if ch == '(' {
            tokens.push(Token::LParen);
            chars.next();
            continue;
        }

        if ch == ')' {
            tokens.push(Token::RParen);
            chars.next();
            continue;
        }

        return Err(format!("invalid character `{ch}` in `{input}`"));
    }

    Ok(tokens)
}

#[derive(Debug, Clone, Copy)]
enum Token {
    Number(i64),
    Op(char),
    LParen,
    RParen,
}

fn parse_expr(tokens: &[Token], mut index: usize) -> Result<(i64, usize), String> {
    let (mut value, next) = parse_term(tokens, index)?;
    index = next;

    while index < tokens.len() {
        match tokens[index] {
            Token::Op('+') => {
                let (rhs, next) = parse_term(tokens, index + 1)?;
                value += rhs;
                index = next;
            }
            Token::Op('-') => {
                let (rhs, next) = parse_term(tokens, index + 1)?;
                value -= rhs;
                index = next;
            }
            _ => break,
        }
    }

    Ok((value, index))
}

fn parse_term(tokens: &[Token], mut index: usize) -> Result<(i64, usize), String> {
    let (mut value, next) = parse_factor(tokens, index)?;
    index = next;

    while index < tokens.len() {
        match tokens[index] {
            Token::Op('*') => {
                let (rhs, next) = parse_factor(tokens, index + 1)?;
                value *= rhs;
                index = next;
            }
            Token::Op('/') => {
                let (rhs, next) = parse_factor(tokens, index + 1)?;
                if rhs == 0 {
                    return Err("division by zero".to_string());
                }
                value /= rhs;
                index = next;
            }
            _ => break,
        }
    }

    Ok((value, index))
}

fn parse_factor(tokens: &[Token], index: usize) -> Result<(i64, usize), String> {
    match tokens.get(index) {
        Some(Token::Number(n)) => Ok((*n, index + 1)),
        Some(Token::Op('-')) => {
            let (value, next) = parse_factor(tokens, index + 1)?;
            Ok((-value, next))
        }
        Some(Token::LParen) => {
            let (value, next) = parse_expr(tokens, index + 1)?;
            match tokens.get(next) {
                Some(Token::RParen) => Ok((value, next + 1)),
                _ => Err("missing closing parenthesis".to_string()),
            }
        }
        _ => Err("expected number or expression".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eval_simple() {
        assert_eq!(eval_expr("2+2").unwrap(), 4);
        assert_eq!(eval_expr("15*2").unwrap(), 30);
        assert_eq!(eval_expr("(10+5)*2").unwrap(), 30);
    }
}
