//! Раскладка плиток: дерево разбиений без наложений. В FFI ходит как JSON (дерево рекурсивное).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TileLayout {
    Leaf(String),
    Row(Vec<TileLayout>),
    Column(Vec<TileLayout>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl TileLayout {
    pub fn ids(&self) -> Vec<String> {
        match self {
            TileLayout::Leaf(id) => vec![id.clone()],
            TileLayout::Row(c) | TileLayout::Column(c) => c.iter().flat_map(|x| x.ids()).collect(),
        }
    }

    /// По умолчанию — ряды по два; нечётный последний занимает всю ширину.
    pub fn automatic(ids: &[String]) -> Option<TileLayout> {
        let mut it = ids.iter();
        let first = it.next()?;
        Some(it.fold(TileLayout::Leaf(first.clone()), |l, id| l.appending(id)))
    }

    pub fn appending(&self, id: &str) -> TileLayout {
        let leaf = TileLayout::Leaf(id.to_string());
        match self {
            TileLayout::Leaf(_) => TileLayout::Row(vec![self.clone(), leaf]),
            TileLayout::Row(c) if c.len() < 2 => TileLayout::Row(c.iter().cloned().chain([leaf]).collect()),
            TileLayout::Row(_) => TileLayout::Column(vec![self.clone(), leaf]),
            TileLayout::Column(rows) => {
                let mut rows = rows.clone();
                match rows.last().cloned() {
                    Some(TileLayout::Leaf(last)) => {
                        *rows.last_mut().unwrap() = TileLayout::Row(vec![TileLayout::Leaf(last), leaf]);
                    }
                    Some(TileLayout::Row(r)) if r.len() < 2 => {
                        *rows.last_mut().unwrap() = TileLayout::Row(r.into_iter().chain([leaf]).collect());
                    }
                    _ => rows.push(leaf),
                }
                TileLayout::Column(rows)
            }
        }
    }

    pub fn removing(&self, id: &str) -> Option<TileLayout> {
        match self {
            TileLayout::Leaf(x) => {
                if x == id {
                    None
                } else {
                    Some(self.clone())
                }
            }
            TileLayout::Row(c) => make(true, c.iter().filter_map(|x| x.removing(id)).collect()),
            TileLayout::Column(c) => make(false, c.iter().filter_map(|x| x.removing(id)).collect()),
        }
    }

    pub fn inserting(&self, id: &str, edge: Edge, target: Option<&str>) -> TileLayout {
        let base = self.removing(id).unwrap_or_else(|| TileLayout::Leaf(id.into()));
        if base.ids() == [id.to_string()] {
            return base;
        }
        let row = matches!(edge, Edge::Left | Edge::Right);
        let before = matches!(edge, Edge::Left | Edge::Top);
        let leaf = TileLayout::Leaf(id.into());
        match target.filter(|t| base.ids().iter().any(|x| x == t)) {
            None => join(base, leaf, row, before),
            Some(t) => base.replacing_leaf(t, &|l| join(l, leaf.clone(), row, before)),
        }
    }

    pub fn swapping(&self, a: &str, b: &str) -> TileLayout {
        match self {
            TileLayout::Leaf(x) => TileLayout::Leaf(if x == a {
                b.into()
            } else if x == b {
                a.into()
            } else {
                x.clone()
            }),
            TileLayout::Row(c) => TileLayout::Row(c.iter().map(|x| x.swapping(a, b)).collect()),
            TileLayout::Column(c) => TileLayout::Column(c.iter().map(|x| x.swapping(a, b)).collect()),
        }
    }

    pub fn synced(&self, ids: &[String]) -> Option<TileLayout> {
        let mut layout = Some(self.clone());
        for id in self.ids() {
            if !ids.contains(&id) {
                layout = layout.and_then(|l| l.removing(&id));
            }
        }
        for id in ids {
            if !layout.as_ref().map(|l| l.ids().contains(id)).unwrap_or(false) {
                layout = Some(layout.map(|l| l.appending(id)).unwrap_or(TileLayout::Leaf(id.clone())));
            }
        }
        layout
    }

    pub fn frames(&self, r: Rect) -> HashMap<String, Rect> {
        let mut out = HashMap::new();
        match self {
            TileLayout::Leaf(id) => {
                out.insert(id.clone(), r);
            }
            TileLayout::Row(c) => {
                let w = r.w / c.len() as f64;
                for (i, x) in c.iter().enumerate() {
                    out.extend(x.frames(Rect { x: r.x + w * i as f64, y: r.y, w, h: r.h }));
                }
            }
            TileLayout::Column(c) => {
                let h = r.h / c.len() as f64;
                for (i, x) in c.iter().enumerate() {
                    out.extend(x.frames(Rect { x: r.x, y: r.y + h * i as f64, w: r.w, h }));
                }
            }
        }
        out
    }

    pub fn neighbor(&self, id: &str, edge: Edge) -> Option<String> {
        let f = self.frames(Rect { x: 0.0, y: 0.0, w: 1.0, h: 1.0 });
        let me = *f.get(id)?;
        let eps = 1e-9;
        let (mx, my) = (me.x + me.w / 2.0, me.y + me.h / 2.0);
        f.iter()
            .filter(|(o, r)| {
                *o != id
                    && match edge {
                        Edge::Left => r.x + r.w <= me.x + eps && r.y + r.h > me.y && r.y < me.y + me.h,
                        Edge::Right => r.x >= me.x + me.w - eps && r.y + r.h > me.y && r.y < me.y + me.h,
                        Edge::Top => r.y + r.h <= me.y + eps && r.x + r.w > me.x && r.x < me.x + me.w,
                        Edge::Bottom => r.y >= me.y + me.h - eps && r.x + r.w > me.x && r.x < me.x + me.w,
                    }
            })
            .min_by(|a, b| {
                let d = |r: &Rect| (r.x + r.w / 2.0 - mx).powi(2) + (r.y + r.h / 2.0 - my).powi(2);
                d(a.1).partial_cmp(&d(b.1)).unwrap()
            })
            .map(|(k, _)| k.clone())
    }

    fn replacing_leaf(&self, target: &str, f: &dyn Fn(TileLayout) -> TileLayout) -> TileLayout {
        match self {
            TileLayout::Leaf(x) => {
                if x == target {
                    f(self.clone())
                } else {
                    self.clone()
                }
            }
            TileLayout::Row(c) => {
                make(true, c.iter().map(|x| x.replacing_leaf(target, f)).collect()).unwrap_or_else(|| self.clone())
            }
            TileLayout::Column(c) => {
                make(false, c.iter().map(|x| x.replacing_leaf(target, f)).collect()).unwrap_or_else(|| self.clone())
            }
        }
    }
}

fn join(a: TileLayout, b: TileLayout, row: bool, before: bool) -> TileLayout {
    make(row, if before { vec![b, a] } else { vec![a, b] }).unwrap()
}

/// Один ребёнок — сам по себе; вложенное той же ориентации — сплющивается.
fn make(row: bool, children: Vec<TileLayout>) -> Option<TileLayout> {
    let mut flat = Vec::new();
    for c in children {
        match c {
            TileLayout::Row(inner) if row => flat.extend(inner),
            TileLayout::Column(inner) if !row => flat.extend(inner),
            x => flat.push(x),
        }
    }
    match flat.len() {
        0 => None,
        1 => flat.pop(),
        _ => Some(if row { TileLayout::Row(flat) } else { TileLayout::Column(flat) }),
    }
}

// MARK: - FFI (JSON)

fn from_json(s: &str) -> Option<TileLayout> {
    serde_json::from_str(s).ok()
}
fn to_json(l: Option<TileLayout>) -> Option<String> {
    l.map(|l| serde_json::to_string(&l).unwrap())
}

#[uniffi::export]
pub fn tiles_automatic(ids: Vec<String>) -> Option<String> {
    to_json(TileLayout::automatic(&ids))
}
#[uniffi::export]
pub fn tiles_ids(layout: String) -> Vec<String> {
    from_json(&layout).map(|l| l.ids()).unwrap_or_default()
}
#[uniffi::export]
pub fn tiles_appending(layout: String, id: String) -> Option<String> {
    to_json(from_json(&layout).map(|l| l.appending(&id)))
}
#[uniffi::export]
pub fn tiles_removing(layout: String, id: String) -> Option<String> {
    to_json(from_json(&layout).and_then(|l| l.removing(&id)))
}
#[uniffi::export]
pub fn tiles_inserting(layout: String, id: String, edge: Edge, target: Option<String>) -> Option<String> {
    to_json(from_json(&layout).map(|l| l.inserting(&id, edge, target.as_deref())))
}
#[uniffi::export]
pub fn tiles_swapping(layout: String, a: String, b: String) -> Option<String> {
    to_json(from_json(&layout).map(|l| l.swapping(&a, &b)))
}
#[uniffi::export]
pub fn tiles_synced(layout: Option<String>, ids: Vec<String>) -> Option<String> {
    match layout.and_then(|l| from_json(&l)) {
        Some(l) => to_json(l.synced(&ids)),
        None => to_json(TileLayout::automatic(&ids)),
    }
}
#[uniffi::export]
pub fn tiles_neighbor(layout: String, id: String, edge: Edge) -> Option<String> {
    from_json(&layout)?.neighbor(&id, edge)
}

/// Плитка и её рамка в координатах области броска.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TileFrame {
    pub id: String,
    pub rect: Rect,
}

/// Куда ляжет брошенная плитка: `edge` с `target` — к краю плитки (`target` = None — к краю всей области),
/// `edge` = None — поменять местами с `target`. `hint` — прямоугольник подсветки.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DropTarget {
    pub edge: Option<Edge>,
    pub target: Option<String>,
    pub hint: Rect,
}

/// Полоса у краёв области, где бросок прикрепляет к стороне всей сетки (точки).
pub const DROP_EDGE_BAND: f64 = 28.0;
/// Доля плитки от края, где бросок делит плитку, а не меняет местами.
pub const DROP_SPLIT_FRACTION: f64 = 0.28;

/// Цель броска в точке (x, y), как на Mac (TileDropDelegate):
/// полоса `DROP_EDGE_BAND` у краёв `bounds` — край всей области, подсветка — треть области;
/// внутри плитки ближайший край ближе `DROP_SPLIT_FRACTION` её размера — делить плитку, подсветка — половина;
/// иначе — поменять местами, подсветка — вся плитка. Своя плитка (`dragged`) и точка вне плиток — None.
/// При равных расстояниях выигрывает край в порядке: левый, правый, верхний, нижний.
#[uniffi::export]
pub fn tiles_drop_target(
    bounds: Rect,
    frames: Vec<TileFrame>,
    x: f64,
    y: f64,
    dragged: Option<String>,
) -> Option<DropTarget> {
    let b = DROP_EDGE_BAND;
    let (w, h) = (bounds.w, bounds.h);
    let (px, py) = (x - bounds.x, y - bounds.y);
    let side = |edge, hint| Some(DropTarget { edge: Some(edge), target: None, hint });
    if px < b {
        return side(Edge::Left, Rect { x: bounds.x, y: bounds.y, w: w / 3.0, h });
    }
    if px > w - b {
        return side(Edge::Right, Rect { x: bounds.x + w * 2.0 / 3.0, y: bounds.y, w: w / 3.0, h });
    }
    if py < b {
        return side(Edge::Top, Rect { x: bounds.x, y: bounds.y, w, h: h / 3.0 });
    }
    if py > h - b {
        return side(Edge::Bottom, Rect { x: bounds.x, y: bounds.y + h * 2.0 / 3.0, w, h: h / 3.0 });
    }
    let f = frames.iter().find(|f| {
        let r = f.rect;
        r.w > 0.0 && r.h > 0.0 && x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h
    })?;
    if dragged.as_deref() == Some(f.id.as_str()) {
        return None;
    }
    let r = f.rect;
    let (fx, fy) = ((x - r.x) / r.w, (y - r.y) / r.h);
    let edges = [
        (fx, Edge::Left, Rect { x: r.x, y: r.y, w: r.w / 2.0, h: r.h }),
        (1.0 - fx, Edge::Right, Rect { x: r.x + r.w / 2.0, y: r.y, w: r.w / 2.0, h: r.h }),
        (fy, Edge::Top, Rect { x: r.x, y: r.y, w: r.w, h: r.h / 2.0 }),
        (1.0 - fy, Edge::Bottom, Rect { x: r.x, y: r.y + r.h / 2.0, w: r.w, h: r.h / 2.0 }),
    ];
    let mut nearest = edges[0];
    for e in &edges[1..] {
        if e.0 < nearest.0 {
            nearest = *e;
        }
    }
    if nearest.0 < DROP_SPLIT_FRACTION {
        return Some(DropTarget { edge: Some(nearest.1), target: Some(f.id.clone()), hint: nearest.2 });
    }
    Some(DropTarget { edge: None, target: Some(f.id.clone()), hint: r })
}

#[cfg(test)]
mod tests {
    use super::*;
    use TileLayout::*;
    fn l(s: &str) -> TileLayout {
        Leaf(s.into())
    }
    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn automatic_and_insert() {
        assert_eq!(
            TileLayout::automatic(&ids(&["1", "2", "3"])),
            Some(Column(vec![Row(vec![l("1"), l("2")]), l("3")]))
        );
        let r = Row(vec![l("1"), l("2")]);
        assert_eq!(r.inserting("3", Edge::Bottom, Some("2")), Row(vec![l("1"), Column(vec![l("2"), l("3")])]));
        assert_eq!(r.inserting("3", Edge::Left, Some("2")), Row(vec![l("1"), l("3"), l("2")]));
        assert_eq!(r.inserting("3", Edge::Bottom, None), Column(vec![Row(vec![l("1"), l("2")]), l("3")]));
    }

    #[test]
    fn move_sync_neighbors() {
        let c = Column(vec![Row(vec![l("1"), l("2")]), l("3")]);
        assert_eq!(c.inserting("1", Edge::Right, Some("3")), Column(vec![l("2"), Row(vec![l("3"), l("1")])]));
        assert_eq!(c.removing("3"), Some(Row(vec![l("1"), l("2")])));
        assert_eq!(Row(vec![l("1"), l("2")]).synced(&ids(&["2", "5"])), Some(Row(vec![l("2"), l("5")])));
        assert_eq!(c.neighbor("1", Edge::Right).as_deref(), Some("2"));
        assert_eq!(c.neighbor("1", Edge::Bottom).as_deref(), Some("3"));
        assert_eq!(c.neighbor("3", Edge::Bottom), None);
        let json = tiles_automatic(ids(&["a", "b"])).unwrap();
        assert_eq!(tiles_ids(json), ids(&["a", "b"]));
    }

    #[test]
    fn drop_target_zones() {
        let bounds = Rect { x: 0.0, y: 0.0, w: 300.0, h: 200.0 };
        let frames = vec![
            TileFrame { id: "a".into(), rect: Rect { x: 0.0, y: 0.0, w: 150.0, h: 200.0 } },
            TileFrame { id: "b".into(), rect: Rect { x: 150.0, y: 0.0, w: 150.0, h: 200.0 } },
        ];
        let t = |x, y, d: Option<&str>| tiles_drop_target(bounds, frames.clone(), x, y, d.map(String::from));
        // Полоса у края — к стороне всей области, подсветка — треть.
        let left = t(10.0, 100.0, None).unwrap();
        assert_eq!((left.edge, left.target), (Some(Edge::Left), None));
        assert_eq!(left.hint, Rect { x: 0.0, y: 0.0, w: 100.0, h: 200.0 });
        assert_eq!(t(100.0, 190.0, Some("a")).unwrap().edge, Some(Edge::Bottom));
        // Край плитки — разделить её, подсветка — половина.
        let split = t(160.0, 100.0, Some("a")).unwrap();
        assert_eq!((split.edge, split.target.as_deref()), (Some(Edge::Left), Some("b")));
        assert_eq!(split.hint, Rect { x: 150.0, y: 0.0, w: 75.0, h: 200.0 });
        // Центр — поменять местами, подсветка — вся плитка.
        let swap = t(225.0, 100.0, Some("a")).unwrap();
        assert_eq!((swap.edge, swap.target.as_deref()), (None, Some("b")));
        // Своя плитка и точка вне плиток — ничего.
        assert_eq!(t(75.0, 100.0, Some("a")), None);
        assert_eq!(tiles_drop_target(bounds, vec![], 150.0, 100.0, None), None);
        // Равные расстояния: левый край раньше верхнего.
        let sq = vec![TileFrame { id: "s".into(), rect: Rect { x: 50.0, y: 50.0, w: 100.0, h: 100.0 } }];
        let corner = tiles_drop_target(bounds, sq, 60.0, 60.0, None).unwrap();
        assert_eq!(corner.edge, Some(Edge::Left));
    }
}
