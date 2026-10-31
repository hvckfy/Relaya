//! Нечёткий поиск для палитры: буквы запроса по порядку, бонус за начало слова и подряд идущие.

fn is_word(c: char) -> bool { c.is_alphanumeric() }

#[uniffi::export]
pub fn fuzzy_score(query: String, text: String) -> Option<i64> {
    let q: Vec<char> = query.to_lowercase().chars().filter(|c| !c.is_whitespace()).collect();
    if q.is_empty() { return Some(0); }
    let lower = text.to_lowercase();
    let t: Vec<char> = lower.chars().collect();
    let (mut score, mut qi, mut prev) = (0i64, 0usize, -2i64);
    for (i, &ch) in t.iter().enumerate() {
        if qi < q.len() && ch == q[qi] {
            score += 1;
            if i as i64 == prev + 1 { score += 5; }
            if i == 0 || !is_word(t[i - 1]) { score += 8; }
            prev = i as i64;
            qi += 1;
        }
    }
    if qi != q.len() { return None; }
    let qs: String = q.iter().collect();
    if let Some(pos) = lower.find(&qs) {
        let before = lower[..pos].chars().last();
        score += if before.map(|c| !is_word(c)).unwrap_or(true) { 20 } else { 5 };
    }
    Some(score * 100 - t.len() as i64)
}

#[uniffi::export]
pub fn fuzzy_score_fields(query: String, fields: Vec<String>) -> Option<i64> {
    fields.into_iter().filter_map(|f| fuzzy_score(query.clone(), f)).max()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranking() {
        assert!(fuzzy_score("dbp".into(), "db-primary".into()).is_some());
        assert!(fuzzy_score("xyz".into(), "db-primary".into()).is_none());
        assert!(fuzzy_score("web".into(), "web-1".into()) > fuzzy_score("web".into(), "jellyfin-webui-backup".into()));
        assert!(fuzzy_score("pp".into(), "proxmox-pve1".into()) > fuzzy_score("pp".into(), "happy".into()));
        assert!(fuzzy_score_fields("192.168".into(), vec!["web-1".into(), "root@192.168.1.5".into()]).is_some());
    }
}
