//! Rails' parameter coercions, reproduced where the wire depends on them: `to_i` on garbage is
//! 0, never a 400; `ActiveModel::Type::Boolean` casts a fixed list of false-ish values; a missing
//! required parameter is a 400 with Rails' own sentence; `present?` is "not blank".

use serde_json::Value;

use crate::error::{ApiError, ApiResult};

/// Ruby's `String#to_i` / `Integer#to_i`: leading whitespace, optional sign, digits, and 0 for
/// anything else. Floats truncate. `nil.to_i` is 0.
pub fn to_i(v: Option<&Value>) -> i64 {
    match v {
        None | Some(Value::Null) => 0,
        Some(Value::Number(n)) => n
            .as_i64()
            .or_else(|| n.as_f64().map(|f| f as i64))
            .unwrap_or(0),
        Some(Value::String(s)) => str_to_i(s),
        Some(Value::Bool(_)) | Some(Value::Array(_)) | Some(Value::Object(_)) => 0,
    }
}

/// `value&.to_i`: absent or null stays absent.
pub fn opt_to_i(v: Option<&Value>) -> Option<i64> {
    match v {
        None | Some(Value::Null) => None,
        other => Some(to_i(other)),
    }
}

pub fn str_to_i(s: &str) -> i64 {
    let s = s.trim_start();
    let (neg, digits) = match s.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, s.strip_prefix('+').unwrap_or(s)),
    };
    let end = digits
        .bytes()
        .position(|b| !b.is_ascii_digit())
        .unwrap_or(digits.len());
    let n: i64 = digits[..end].parse().unwrap_or(0);
    if neg { -n } else { n }
}

/// `ActiveModel::Type::Boolean.new.cast(v) || false`.
pub fn to_bool(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64() != Some(0.0),
        Some(Value::String(s)) => !matches!(
            s.as_str(),
            "" | "0" | "f" | "F" | "false" | "FALSE" | "off" | "OFF"
        ),
        Some(_) => true,
    }
}

/// A string value, if present and non-blank (`params[:x].present?`).
pub fn present_str(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) if !s.trim().is_empty() => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
    }
}

/// A string value as given, or None for absent/null (a blank string is kept — Rails stores it).
pub fn opt_str(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
    }
}

/// `params.require(:name)`: a 400 when the value is missing, null, or blank.
pub fn require_str(body: &serde_json::Map<String, Value>, name: &str) -> ApiResult<String> {
    present_str(body.get(name)).ok_or_else(|| {
        ApiError::BadRequest(format!(
            "param is missing or the value is empty or invalid: {name}"
        ))
    })
}

/// `Integer#clamp` after `to_i`, for `limit` query parameters.
pub fn clamp(v: i64, lo: i64, hi: i64) -> i64 {
    v.max(lo).min(hi)
}

/// Ruby's `inspect` for the values a manifest hash slot can hold, for the 422 message.
pub fn ruby_inspect(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => "nil".to_string(),
        Some(Value::String(s)) => format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"")),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(other) => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn to_i_is_rubys() {
        assert_eq!(to_i(Some(&json!(42))), 42);
        assert_eq!(to_i(Some(&json!("42"))), 42);
        assert_eq!(to_i(Some(&json!(" 12abc"))), 12);
        assert_eq!(to_i(Some(&json!("abc"))), 0);
        assert_eq!(to_i(Some(&json!("-7"))), -7);
        assert_eq!(to_i(Some(&json!(3.9))), 3);
        assert_eq!(to_i(None), 0);
        assert_eq!(opt_to_i(None), None);
        assert_eq!(opt_to_i(Some(&json!(null))), None);
        assert_eq!(opt_to_i(Some(&json!("5"))), Some(5));
    }

    #[test]
    fn boolean_cast_is_active_models() {
        for v in [
            json!(true),
            json!("true"),
            json!("1"),
            json!(1),
            json!("yes"),
            json!("anything"),
        ] {
            assert!(to_bool(Some(&v)), "{v}");
        }
        for v in [
            json!(false),
            json!("false"),
            json!("0"),
            json!(0),
            json!("f"),
            json!("off"),
            json!(""),
            json!(null),
        ] {
            assert!(!to_bool(Some(&v)), "{v}");
        }
        assert!(!to_bool(None));
    }

    #[test]
    fn require_str_uses_rails_wording() {
        let body = serde_json::Map::new();
        let err = require_str(&body, "node_id").unwrap_err();
        assert!(
            matches!(err, ApiError::BadRequest(m) if m == "param is missing or the value is empty or invalid: node_id")
        );
    }

    #[test]
    fn inspect_quotes_like_ruby() {
        assert_eq!(ruby_inspect(None), "nil");
        assert_eq!(
            ruby_inspect(Some(&json!("not-a-real-hash"))),
            "\"not-a-real-hash\""
        );
        assert_eq!(ruby_inspect(Some(&json!(7))), "7");
    }
}
