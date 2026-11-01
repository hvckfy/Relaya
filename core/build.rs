// Сборка прослойки FreeRDP (feature rdp-freerdp). Без этой feature скрипт ничего не делает.
fn main() {
    #[cfg(feature = "rdp-freerdp")]
    freerdp();
    #[cfg(feature = "vnc-royal")]
    royalvnc();
}

/// RoyalVNCKit (feature vnc-royal): только линковка — C API объявлен в remote_vnc.rs.
#[cfg(feature = "vnc-royal")]
fn royalvnc() {
    println!("cargo:rerun-if-env-changed=ROYALVNC_DIR");
    let dir = std::env::var("ROYALVNC_DIR").expect("ROYALVNC_DIR: каталог с RoyalVNCKit (.github/actions/royalvnc)");
    println!("cargo:rustc-link-search=native={dir}");
    println!("cargo:rustc-link-lib=dylib=RoyalVNCKit");
    // Linux: libRoyalVNCKit.so лежит рядом с librelaya_core.so — искать её там.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
    }
}

#[cfg(feature = "rdp-freerdp")]
fn freerdp() {
    println!("cargo:rerun-if-env-changed=FREERDP_DIR");
    println!("cargo:rerun-if-changed=native/relaya_rdp.c");
    println!("cargo:rerun-if-changed=native/relaya_rdp.h");
    let dir =
        std::env::var("FREERDP_DIR").expect("FREERDP_DIR: каталог FreeRDP 3 с include/ и lib/ (артефакт freerdp.yml)");
    cc::Build::new()
        .file("native/relaya_rdp.c")
        .include("native")
        .include(format!("{dir}/include/freerdp3"))
        .include(format!("{dir}/include/winpr3"))
        .include(format!("{dir}/include"))
        .warnings(false)
        .compile("relaya_rdp");
    println!("cargo:rustc-link-search=native={dir}/lib");
    for lib in ["freerdp-client3", "freerdp3", "winpr3"] {
        println!("cargo:rustc-link-lib=dylib={lib}");
    }
}
