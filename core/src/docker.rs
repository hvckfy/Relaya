//! Контейнеры Docker: команда списка, разбор `docker ps -a --format '{{json .}}'`, команды действий.

use crate::shell_quote;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DockerContainer {
    pub id: String,
    pub name: String,
    pub image: String,
    pub state: String,
    pub status: String,
    pub ports: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DockerList {
    Containers { list: Vec<DockerContainer> },
    NotInstalled,
    PermissionDenied,
    Failed { message: String },
}

fn running(c: &DockerContainer) -> bool { c.state == "running" || c.state == "restarting" }

#[uniffi::export]
pub fn docker_list_command() -> String {
    "command -v docker >/dev/null 2>&1 || { echo RELAYA_NO_DOCKER; exit 0; }; docker ps -a --format '{{json .}}'".into()
}

#[uniffi::export]
pub fn docker_parse(stdout: String, stderr: String, status: i32) -> DockerList {
    if stdout.contains("RELAYA_NO_DOCKER") { return DockerList::NotInstalled; }
    if stderr.contains("permission denied") || stderr.contains("Got permission denied") { return DockerList::PermissionDenied; }
    let mut list: Vec<DockerContainer> = stdout.lines().filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok()).map(|o| {
        let s = |k: &str| o.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        DockerContainer { id: s("ID"), name: s("Names"), image: s("Image"), state: s("State").to_lowercase(), status: s("Status"), ports: s("Ports") }
    }).collect();
    if list.is_empty() && status != 0 {
        return DockerList::Failed { message: stderr.lines().last().map(str::to_string).unwrap_or(format!("exit {status}")) };
    }
    list.sort_by(|a, b| running(b).cmp(&running(a)).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    DockerList::Containers { list }
}

#[uniffi::export]
pub fn docker_action_command(action: String, name: String) -> String { format!("docker {action} {}", shell_quote(&name)) }
#[uniffi::export]
pub fn docker_logs_command(name: String) -> String { format!("docker logs -f --tail 200 {}", shell_quote(&name)) }
#[uniffi::export]
pub fn docker_shell_command(name: String) -> String {
    format!("docker exec -it {} sh -c 'command -v bash >/dev/null && exec bash || exec sh'", shell_quote(&name))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parse_variants() {
        assert_eq!(docker_parse("RELAYA_NO_DOCKER\n".into(), "".into(), 0), DockerList::NotInstalled);
        assert_eq!(docker_parse("".into(), "Got permission denied while trying".into(), 1), DockerList::PermissionDenied);
        let out = r#"{"ID":"a","Names":"web","Image":"nginx","State":"exited","Status":"Exited","Ports":""}
{"ID":"b","Names":"api","Image":"x","State":"running","Status":"Up","Ports":"80"}"#;
        match docker_parse(out.into(), "".into(), 0) {
            DockerList::Containers { list } => assert_eq!(list.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["api", "web"]),
            x => panic!("{x:?}"),
        }
        assert_eq!(docker_action_command("stop".into(), "my app".into()), "docker stop 'my app'");
    }
}
