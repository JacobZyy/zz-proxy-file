use std::collections::{HashMap, HashSet};

use serde_json::Value;

const BUILTIN_POLICIES: &[&str] = &[
    "DIRECT",
    "REJECT",
    "REJECT-DROP",
    "PASS",
    "COMPATIBLE",
    "GLOBAL",
];

const RULE_TYPES: &[&str] = &[
    "AND",
    "DOMAIN",
    "DOMAIN-KEYWORD",
    "DOMAIN-REGEX",
    "DOMAIN-SUFFIX",
    "DOMAIN-WILDCARD",
    "DSCP",
    "DST-PORT",
    "GEOIP",
    "GEOSITE",
    "IN-NAME",
    "IN-PORT",
    "IN-TYPE",
    "IN-USER",
    "IP-ASN",
    "IP-CIDR",
    "IP-CIDR6",
    "IP-SUFFIX",
    "MATCH",
    "NETWORK",
    "NOT",
    "OR",
    "PROCESS-NAME",
    "PROCESS-NAME-REGEX",
    "PROCESS-NAME-WILDCARD",
    "PROCESS-PATH",
    "PROCESS-PATH-REGEX",
    "PROCESS-PATH-WILDCARD",
    "RULE-SET",
    "SRC-GEOIP",
    "SRC-IP-ASN",
    "SRC-IP-CIDR",
    "SRC-IP-SUFFIX",
    "SRC-PORT",
    "SUB-RULE",
    "UID",
];

pub fn parse_and_validate(yaml: &str) -> Result<Value, String> {
    let document = serde_yaml::from_str(yaml).map_err(|error| format!("invalid YAML: {error}"))?;
    validate(&document)?;
    Ok(document)
}

pub fn validate(document: &Value) -> Result<(), String> {
    let root = document
        .as_object()
        .ok_or_else(|| "document must be an object".to_owned())?;
    let proxies = required_array(root.get("proxies"), "proxies")?;
    let groups = required_array(root.get("proxy-groups"), "proxy-groups")?;
    let rules = required_array(root.get("rules"), "rules")?;

    if let Some(port) = root.get("mixed-port") {
        port.as_u64()
            .filter(|port| (1..=65_535).contains(port))
            .ok_or_else(|| "mixed-port must be an integer from 1 to 65535".to_owned())?;
    }

    let mut all_names = HashSet::new();
    let mut proxy_names = HashSet::new();
    for (index, proxy) in proxies.iter().enumerate() {
        let object = proxy
            .as_object()
            .ok_or_else(|| format!("proxy[{index}] must be an object"))?;
        let name = entry_name(proxy, "proxy", index)?;
        register_name(name, "proxy", &mut all_names)?;
        proxy_names.insert(name.to_owned());

        let proxy_type = object
            .get("type")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| format!("proxy `{name}` requires non-empty string field `type`"))?;
        if matches!(proxy_type, "http" | "socks5" | "ss" | "vmess" | "trojan") {
            object
                .get("server")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| {
                    format!("proxy `{name}` requires non-empty string field `server`")
                })?;
            object
                .get("port")
                .and_then(Value::as_u64)
                .filter(|port| (1..=65_535).contains(port))
                .ok_or_else(|| {
                    format!("proxy `{name}` requires integer field `port` from 1 to 65535")
                })?;
        }
        for field in match proxy_type {
            "ss" => &["cipher", "password"][..],
            "vmess" => &["uuid"][..],
            "trojan" => &["password"][..],
            _ => &[],
        } {
            object
                .get(*field)
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| {
                    format!("proxy `{name}` requires non-empty string field `{field}`")
                })?;
        }
    }

    let mut group_names = HashSet::new();
    for (index, group) in groups.iter().enumerate() {
        let object = group
            .as_object()
            .ok_or_else(|| format!("proxy-groups[{index}] must be an object"))?;
        let name = entry_name(group, "proxy group", index)?;
        register_name(name, "proxy group", &mut all_names)?;
        group_names.insert(name.to_owned());

        match object.get("type").and_then(Value::as_str) {
            Some("select") => {}
            Some(group_type) => {
                return Err(format!(
                    "proxy group `{name}` has unsupported type `{group_type}`; only `select` is allowed"
                ));
            }
            None => return Err(format!("proxy group `{name}` requires string field `type`")),
        }
    }

    let mut graph = HashMap::new();
    for (index, group) in groups.iter().enumerate() {
        let object = group.as_object().expect("group object checked above");
        let name = entry_name(group, "proxy group", index)?;
        let members = required_array(
            object.get("proxies"),
            &format!("proxy group `{name}` proxies"),
        )?;
        if members.is_empty() {
            return Err(format!(
                "proxy group `{name}` must contain at least one proxy"
            ));
        }

        let mut group_references = Vec::new();
        for (member_index, member) in members.iter().enumerate() {
            let reference = member
                .as_str()
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| {
                    format!(
                        "proxy group `{name}` proxies[{member_index}] must be a non-empty string"
                    )
                })?;
            if group_names.contains(reference) {
                group_references.push(reference.to_owned());
            } else if !proxy_names.contains(reference) && !is_builtin(reference) {
                return Err(format!(
                    "proxy group `{name}` references unknown proxy or group `{reference}`"
                ));
            }
        }
        graph.insert(name.to_owned(), group_references);
    }
    validate_acyclic(&graph)?;

    for (index, rule) in rules.iter().enumerate() {
        let rule = rule
            .as_str()
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| format!("rules[{index}] must be a non-empty string"))?;
        let policy = rule_policy(rule).map_err(|error| format!("rules[{index}]: {error}"))?;
        if !all_names.contains(policy) && !is_builtin(policy) {
            return Err(format!(
                "rule `{rule}` references unknown policy `{policy}`"
            ));
        }
    }

    Ok(())
}

fn required_array<'a>(value: Option<&'a Value>, field: &str) -> Result<&'a Vec<Value>, String> {
    value
        .and_then(Value::as_array)
        .ok_or_else(|| format!("document requires array field `{field}`"))
}

fn entry_name<'a>(entry: &'a Value, kind: &str, index: usize) -> Result<&'a str, String> {
    entry
        .as_object()
        .ok_or_else(|| format!("{kind}[{index}] must be an object"))?
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| !name.trim().is_empty())
        .ok_or_else(|| format!("{kind}[{index}] requires non-empty string field `name`"))
}

fn register_name(name: &str, kind: &str, names: &mut HashSet<String>) -> Result<(), String> {
    if is_builtin(name) {
        return Err(format!("{kind} name `{name}` is reserved"));
    }
    if !names.insert(name.to_owned()) {
        return Err(format!("duplicate proxy or group name `{name}`"));
    }
    Ok(())
}

fn is_builtin(name: &str) -> bool {
    BUILTIN_POLICIES.contains(&name)
}

fn rule_policy(rule: &str) -> Result<&str, String> {
    let parts: Vec<_> = rule.split(',').map(str::trim).collect();
    if parts.len() < 2 || parts.iter().any(|field| field.is_empty()) {
        return Err("rule must contain non-empty comma-separated fields".to_owned());
    }
    let fields = if parts.last() == Some(&"no-resolve") {
        &parts[..parts.len() - 1]
    } else {
        &parts[..]
    };

    let rule_type = fields[0];
    if !RULE_TYPES.contains(&rule_type) {
        return Err(format!("unsupported rule type `{rule_type}`"));
    }
    if rule_type == "MATCH" && fields.len() != 2 {
        return Err("MATCH rule must contain exactly a type and policy".to_owned());
    }
    if rule_type != "MATCH" && fields.len() < 3 {
        return Err(format!(
            "{rule_type} rule requires a match value and policy"
        ));
    }

    fields
        .last()
        .copied()
        .filter(|policy| !policy.is_empty())
        .ok_or_else(|| "rule is missing policy".to_owned())
}

fn validate_acyclic(graph: &HashMap<String, Vec<String>>) -> Result<(), String> {
    fn visit(
        name: &str,
        graph: &HashMap<String, Vec<String>>,
        visiting: &mut HashSet<String>,
        visited: &mut HashSet<String>,
    ) -> Result<(), String> {
        if visited.contains(name) {
            return Ok(());
        }
        if !visiting.insert(name.to_owned()) {
            return Err(format!("proxy group cycle includes `{name}`"));
        }
        if let Some(references) = graph.get(name) {
            for reference in references {
                visit(reference, graph, visiting, visited)?;
            }
        }
        visiting.remove(name);
        visited.insert(name.to_owned());
        Ok(())
    }

    let mut visiting = HashSet::new();
    let mut visited = HashSet::new();
    for name in graph.keys() {
        visit(name, graph, &mut visiting, &mut visited)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{parse_and_validate, validate};

    #[test]
    fn bundled_config_is_valid() {
        parse_and_validate(include_str!("../../../clash.yaml")).unwrap();
    }

    #[test]
    fn rejects_unknown_group_reference() {
        let document = json!({
            "proxies": [],
            "proxy-groups": [{"name": "selector", "type": "select", "proxies": ["missing"]}],
            "rules": ["MATCH,selector"]
        });
        assert!(
            validate(&document)
                .unwrap_err()
                .contains("unknown proxy or group")
        );
    }

    #[test]
    fn rejects_incomplete_http_proxy() {
        let document = json!({
            "proxies": [{"name": "incomplete", "type": "http", "server": ""}],
            "proxy-groups": [{"name": "selector", "type": "select", "proxies": ["incomplete"]}],
            "rules": ["MATCH,selector"]
        });
        assert!(validate(&document).unwrap_err().contains("field `server`"));
    }

    #[test]
    fn rejects_invalid_mixed_port() {
        let document = json!({
            "mixed-port": 0,
            "proxies": [],
            "proxy-groups": [],
            "rules": ["MATCH,DIRECT"]
        });
        assert!(validate(&document).unwrap_err().contains("mixed-port"));
    }

    #[test]
    fn rejects_group_cycles() {
        let document = json!({
            "proxies": [],
            "proxy-groups": [
                {"name": "one", "type": "select", "proxies": ["two"]},
                {"name": "two", "type": "select", "proxies": ["one"]}
            ],
            "rules": ["MATCH,one"]
        });
        assert!(validate(&document).unwrap_err().contains("cycle"));
    }

    #[test]
    fn rejects_duplicate_names() {
        let document = json!({
            "proxies": [{
                "name": "same",
                "type": "http",
                "server": "127.0.0.1",
                "port": 8080
            }],
            "proxy-groups": [{"name": "same", "type": "select", "proxies": ["DIRECT"]}],
            "rules": ["MATCH,DIRECT"]
        });
        assert!(validate(&document).unwrap_err().contains("duplicate"));
    }

    #[test]
    fn rejects_non_select_groups() {
        let document = json!({
            "proxies": [],
            "proxy-groups": [{"name": "auto", "type": "url-test", "proxies": ["DIRECT"]}],
            "rules": ["MATCH,auto"]
        });
        assert!(validate(&document).unwrap_err().contains("only `select`"));
    }

    #[test]
    fn rejects_unknown_rule_policy() {
        let document = json!({
            "proxies": [],
            "proxy-groups": [],
            "rules": ["MATCH,missing"]
        });
        assert!(validate(&document).unwrap_err().contains("unknown policy"));
    }

    #[test]
    fn rejects_unknown_rule_type() {
        let document = json!({
            "proxies": [],
            "proxy-groups": [],
            "rules": ["BANANA,DIRECT"]
        });
        assert!(
            validate(&document)
                .unwrap_err()
                .contains("unsupported rule type")
        );
    }

    #[test]
    fn rejects_match_with_payload() {
        let document = json!({
            "proxies": [],
            "proxy-groups": [],
            "rules": ["MATCH,example.com,DIRECT"]
        });
        assert!(validate(&document).unwrap_err().contains("exactly"));
    }

    #[test]
    fn rejects_rule_without_payload_before_no_resolve() {
        let document = json!({
            "proxies": [],
            "proxy-groups": [],
            "rules": ["DOMAIN,DIRECT,no-resolve"]
        });
        assert!(validate(&document).unwrap_err().contains("match value"));
    }
}
