pub fn parse_config(text: &str) -> Vec<String> {
    let mut commands = Vec::new();

    for line in text.lines() {
        let line = line.trim();

        let command = line
            .split('%')
            .next()
            .unwrap_or("")
            .split('#')
            .next()
            .unwrap_or("")
            .trim();

        if command.is_empty() {
            continue;
        }

        commands.push(command.to_string());
    }
    commands
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_comments_and_empty_lines() {
        let config = r#"
            % Comment
            sensorStop

            channelCfg 15 7 0 % Inline comment
            # Another comment
            sensorStart
        "#;

        let result = parse_config(config);

        assert_eq!(
            result,
            vec!["sensorStop", "channelCfg 15 7 0", "sensorStart",]
        );
    }
}

#[test]
fn golf_config_is_valid() {
    let config = include_str!("../../configs/golf.cfg");

    let commands = parse_config(config);

    assert!(!commands.is_empty(), "Golf CFG must not be empty");

    assert!(
        commands.iter().any(|cmd| cmd.starts_with("profileCfg ")),
        "Missing profileCfg"
    );

    assert!(
        commands.iter().any(|cmd| cmd.starts_with("chirpCfg ")),
        "Missing chirpCfg"
    );

    assert!(
        commands.iter().any(|cmd| cmd.starts_with("frameCfg ")),
        "Missing frameCfg"
    );
}
