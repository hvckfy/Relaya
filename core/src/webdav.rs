//! Минимальный HTTP/1.1 + WebDAV (класс 1–2) для моста «SFTP → диск в Finder/Проводнике».

use chrono::{DateTime, Datelike, NaiveDate, NaiveDateTime, TimeZone, Utc};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DavRequest {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl DavRequest {
    pub fn header(&self, name: &str) -> Option<&String> { self.headers.get(&name.to_lowercase()) }
    pub fn depth(&self) -> u8 { if self.header("depth").map(|d| d == "0").unwrap_or(false) { 0 } else { 1 } }
}

#[uniffi::export]
pub fn dav_depth(req: DavRequest) -> u8 { req.depth() }

fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    hay.get(from..)?.windows(needle.len()).position(|w| w == needle).map(|p| p + from)
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) { out.push(v); i += 3; continue; }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Пошаговый разбор: копит байты, отдаёт готовые запросы (Content-Length и chunked).
#[derive(Default, uniffi::Object)]
pub struct DavParser { buffer: std::sync::Mutex<Vec<u8>> }

#[uniffi::export]
impl DavParser {
    #[uniffi::constructor]
    pub fn new() -> Self { Self::default() }

    pub fn feed(&self, data: Vec<u8>) -> Vec<DavRequest> {
        let mut buf = self.buffer.lock().unwrap();
        buf.extend(data);
        let mut out = Vec::new();
        while let Some(r) = next(&mut buf) { out.push(r); }
        out
    }
}

fn next(buf: &mut Vec<u8>) -> Option<DavRequest> {
    let head_end = find(buf, b"\r\n\r\n", 0)?;
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.split("\r\n");
    let first: Vec<&str> = lines.next()?.split(' ').collect();
    if first.len() < 2 { buf.clear(); return None; }
    let mut headers = HashMap::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') { headers.insert(k.to_lowercase(), v.trim().to_string()); }
    }
    let body_start = head_end + 4;
    let (body, consumed) = if headers.get("transfer-encoding").map(|v| v.to_lowercase().contains("chunked")).unwrap_or(false) {
        dechunk(buf, body_start)?
    } else {
        let len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
        if buf.len() - body_start < len { return None; }
        (buf[body_start..body_start + len].to_vec(), body_start + len)
    };
    buf.drain(..consumed);
    let raw_path = first[1].split('?').next().unwrap_or("");
    Some(DavRequest { method: first[0].to_uppercase(), path: percent_decode(raw_path), headers, body })
}

fn dechunk(data: &[u8], start: usize) -> Option<(Vec<u8>, usize)> {
    let mut out = Vec::new();
    let mut i = start;
    loop {
        let line_end = find(data, b"\r\n", i)?;
        let size_line = String::from_utf8_lossy(&data[i..line_end]).to_string();
        let size = usize::from_str_radix(size_line.split(';').next()?.trim(), 16).ok()?;
        let chunk_start = line_end + 2;
        if data.len() < chunk_start + size + 2 { return None; }
        if size == 0 { return Some((out, find(data, b"\r\n", chunk_start)? + 2)); }
        out.extend_from_slice(&data[chunk_start..chunk_start + size]);
        i = chunk_start + size + 2;
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DavEntry {
    pub href: String,
    pub name: String,
    pub is_directory: bool,
    pub size: i64,
    /// Unix-время.
    pub modified: f64,
}

fn escape(s: &str) -> String { s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;") }

fn encode_path(p: &str) -> String {
    p.bytes().map(|b| match b {
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' | b'!' | b'$' | b'&' | b'\'' | b'(' | b')'
        | b'*' | b'+' | b',' | b';' | b'=' | b':' | b'@' => (b as char).to_string(),
        _ => format!("%{b:02X}"),
    }).collect()
}

fn ts(t: f64) -> DateTime<Utc> { Utc.timestamp_opt(t as i64, 0).single().unwrap_or_default() }
fn http_date(t: f64) -> String { ts(t).format("%a, %d %b %Y %H:%M:%S GMT").to_string() }

#[uniffi::export]
pub fn dav_multistatus(entries: Vec<DavEntry>) -> Vec<u8> {
    let mut x = String::from(r#"<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">"#);
    for e in entries {
        x += &format!("<D:response><D:href>{}</D:href><D:propstat><D:prop>", escape(&encode_path(&e.href)));
        x += &format!("<D:displayname>{}</D:displayname>", escape(&e.name));
        x += &format!("<D:getlastmodified>{}</D:getlastmodified>", http_date(e.modified));
        x += &format!("<D:creationdate>{}</D:creationdate>", ts(e.modified).format("%Y-%m-%dT%H:%M:%SZ"));
        if e.is_directory {
            x += "<D:resourcetype><D:collection/></D:resourcetype>";
        } else {
            x += &format!("<D:resourcetype/><D:getcontentlength>{}</D:getcontentlength><D:getcontenttype>application/octet-stream</D:getcontenttype>", e.size);
        }
        x += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>";
        x += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>";
    }
    x += "</D:multistatus>";
    x.into_bytes()
}

#[uniffi::export]
pub fn dav_lock_response(token: String, path: String) -> Vec<u8> {
    format!(r#"<?xml version="1.0" encoding="utf-8"?><D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth><D:timeout>Second-3600</D:timeout><D:locktoken><D:href>{token}</D:href></D:locktoken><D:lockroot><D:href>{}</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>"#,
            escape(&encode_path(&path))).into_bytes()
}

#[uniffi::export]
pub fn dav_response(status: u16, reason: String, headers: HashMap<String, String>, body: Vec<u8>) -> Vec<u8> {
    let mut all: Vec<(String, String)> = headers.into_iter().collect();
    all.push(("Content-Length".into(), body.len().to_string()));
    all.push(("DAV".into(), "1, 2".into()));
    all.push(("MS-Author-Via".into(), "DAV".into()));
    all.sort();
    let mut h = format!("HTTP/1.1 {status} {reason}\r\n");
    for (k, v) in all { h += &format!("{k}: {v}\r\n"); }
    h += "\r\n";
    let mut out = h.into_bytes();
    out.extend(body);
    out
}

/// `http://127.0.0.1:port/a/b` → `/a/b`.
#[uniffi::export]
pub fn dav_destination_path(header: Option<String>) -> Option<String> {
    let h = header?;
    let path = h.find("://").and_then(|i| h[i + 3..].find('/').map(|j| &h[i + 3 + j..])).unwrap_or(&h);
    let p = percent_decode(path);
    Some(if p.is_empty() { "/".into() } else { p })
}

/// Служебные файлы Finder (`._*`, `.DS_Store`).
#[uniffi::export]
pub fn dav_is_finder_junk(name: String) -> bool {
    name.starts_with("._") || [".DS_Store", ".localized", ".hidden"].contains(&name.as_str())
}

/// Дата из `ls -la` sftp: `Oct 29 12:00` (текущий год) или `Oct 29  2024` → Unix-время.
#[uniffi::export]
pub fn dav_date_from_listing(s: String, now: f64) -> f64 {
    let parts: Vec<&str> = s.split_whitespace().collect();
    if parts.len() != 3 { return now; }
    let month = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"].iter().position(|m| *m == parts[0]);
    let (Some(month), Ok(day)) = (month, parts[1].parse::<u32>()) else { return now };
    let now_dt = ts(now);
    if let Some((h, m)) = parts[2].split_once(':') {
        let (Ok(h), Ok(m)) = (h.parse::<u32>(), m.parse::<u32>()) else { return now };
        let mk = |y: i32| NaiveDate::from_ymd_opt(y, month as u32 + 1, day).and_then(|d| d.and_hms_opt(h, m, 0));
        let Some(d) = mk(now_dt.year()) else { return now };
        let t = Utc.from_utc_datetime(&d).timestamp() as f64;
        if t > now + 86400.0 { return mk(now_dt.year() - 1).map(|d: NaiveDateTime| Utc.from_utc_datetime(&d).timestamp() as f64).unwrap_or(t); }
        return t;
    }
    let Ok(year) = parts[2].parse::<i32>() else { return now };
    NaiveDate::from_ymd_opt(year, month as u32 + 1, day).and_then(|d| d.and_hms_opt(0, 0, 0))
        .map(|d| Utc.from_utc_datetime(&d).timestamp() as f64).unwrap_or(now)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parse_requests() {
        let p = DavParser::new();
        let raw = b"PUT /t/web/a%20b.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloPROPFIND /t/web/ HTTP/1.1\r\nDepth: 0\r\n\r\n";
        let mut r = p.feed(raw[..40].to_vec());
        r.extend(p.feed(raw[40..].to_vec()));
        assert_eq!(r.len(), 2);
        assert_eq!((r[0].method.as_str(), r[0].path.as_str(), r[0].body.as_slice()), ("PUT", "/t/web/a b.txt", &b"hello"[..]));
        assert_eq!(r[1].depth(), 0);
        let c = DavParser::new().feed(b"PUT /f HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".to_vec());
        assert_eq!(c[0].body, b"hello world");
        assert!(DavParser::new().feed(b"PUT /g HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab".to_vec()).is_empty());
    }

    #[test]
    fn xml_and_helpers() {
        let x = String::from_utf8(dav_multistatus(vec![
            DavEntry { href: "/t/web/".into(), name: "web".into(), is_directory: true, size: 0, modified: 0.0 },
            DavEntry { href: "/t/web/a & b.txt".into(), name: "a & b.txt".into(), is_directory: false, size: 12, modified: 0.0 },
        ])).unwrap();
        assert!(x.contains("<D:collection/>") && x.contains("<D:getcontentlength>12</D:getcontentlength>"));
        assert!(x.contains("Thu, 01 Jan 1970 00:00:00 GMT"));
        assert!(x.contains("a%20&amp;%20b.txt"));
        assert_eq!(dav_destination_path(Some("http://127.0.0.1:5000/t/web/new%20name".into())).as_deref(), Some("/t/web/new name"));
        assert!(dav_is_finder_junk("._photo.jpg".into()) && !dav_is_finder_junk("notes.txt".into()));
        let now = 1_793_448_000.0; // 2026-10-31
        assert!(dav_date_from_listing("Oct 29 12:00".into(), now) < now);
        let old = dav_date_from_listing("Mar 3  2024".into(), now);
        assert_eq!(ts(old).year(), 2024);
    }
}
