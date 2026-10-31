//! Построчный diff (LCS) для превью изменений конфига.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DiffKind { Same, Added, Removed }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DiffLine {
    pub kind: DiffKind,
    pub text: String,
}

#[uniffi::export]
pub fn line_diff(old: Vec<String>, new: Vec<String>) -> Vec<DiffLine> {
    let (n, m) = (old.len(), new.len());
    let mut lcs = vec![vec![0usize; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if old[i] == new[j] { lcs[i + 1][j + 1] + 1 } else { lcs[i + 1][j].max(lcs[i][j + 1]) };
        }
    }
    let mut out = Vec::new();
    let (mut i, mut j) = (0, 0);
    while i < n || j < m {
        if i < n && j < m && old[i] == new[j] {
            out.push(DiffLine { kind: DiffKind::Same, text: old[i].clone() }); i += 1; j += 1;
        } else if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) {
            out.push(DiffLine { kind: DiffKind::Added, text: new[j].clone() }); j += 1;
        } else {
            out.push(DiffLine { kind: DiffKind::Removed, text: old[i].clone() }); i += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn diff_basic() {
        let d = line_diff(vec!["a".into(), "b".into()], vec!["a".into(), "c".into()]);
        assert_eq!(d.iter().map(|l| l.kind).collect::<Vec<_>>(), [DiffKind::Same, DiffKind::Added, DiffKind::Removed]);
    }
}
