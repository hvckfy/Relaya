//! `localhost:3000`, `127.0.0.1:8080`, `0.0.0.0:5173`, `[::1]:9000` в выводе — порты на сервере.

use regex::Regex;

#[uniffi::export]
pub fn local_ports_find(text: String) -> Vec<i64> {
    let re = Regex::new(r"(?i)(?:https?://)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})\b").unwrap();
    let mut seen = std::collections::HashSet::new();
    re.captures_iter(&text).filter_map(|c| c[1].parse::<i64>().ok())
        .filter(|p| (1..=65535).contains(p) && *p != 22 && seen.insert(*p))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn finds() {
        let out = "Local:   http://localhost:5173/\nlistening on 0.0.0.0:8080, 127.0.0.1:8080 and [::1]:9000";
        assert_eq!(local_ports_find(out.into()), [5173, 8080, 9000]);
        assert!(local_ports_find("ssh localhost:22 and 10.0.0.1:3000 and localhost:99999".into()).is_empty());
    }
}
