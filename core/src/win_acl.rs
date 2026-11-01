//! Windows: права «только владелец» для файлов с секретами — аналог 0600 на Unix.

use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, ERROR_SUCCESS, GENERIC_ALL, HANDLE};
use windows_sys::Win32::Security::Authorization::{
    SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W, SET_ACCESS, SE_FILE_OBJECT, TRUSTEE_IS_SID,
    TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
};
use windows_sys::Win32::Security::{
    CreateWellKnownSid, GetTokenInformation, TokenUser, WinLocalSystemSid, ACL, DACL_SECURITY_INFORMATION,
    NO_INHERITANCE, PROTECTED_DACL_SECURITY_INFORMATION, TOKEN_QUERY, TOKEN_USER,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

/// Заменить DACL файла: без наследования от папки, полный доступ текущему пользователю и SYSTEM, больше никому.
/// OpenSSH-Windows принимает такой ключ; с унаследованным ACL `.ssh` отвечает «UNPROTECTED PRIVATE KEY FILE».
pub(crate) fn owner_only(path: &Path) -> std::io::Result<()> {
    let user = current_user_sid()?;
    let mut system = [0u8; 68]; // SECURITY_MAX_SID_SIZE
    let mut size = system.len() as u32;
    // SAFETY: буфер размера SECURITY_MAX_SID_SIZE, size — его длина.
    if unsafe { CreateWellKnownSid(WinLocalSystemSid, std::ptr::null_mut(), system.as_mut_ptr().cast(), &mut size) }
        == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    let entry = |sid: *mut u8| EXPLICIT_ACCESS_W {
        grfAccessPermissions: GENERIC_ALL,
        grfAccessMode: SET_ACCESS,
        grfInheritance: NO_INHERITANCE,
        Trustee: TRUSTEE_W {
            pMultipleTrustee: std::ptr::null_mut(),
            MultipleTrusteeOperation: 0,
            TrusteeForm: TRUSTEE_IS_SID,
            TrusteeType: TRUSTEE_IS_UNKNOWN,
            ptstrName: sid.cast(),
        },
    };
    let mut user_sid = user;
    let entries = [entry(user_sid_ptr(&mut user_sid)), entry(system.as_mut_ptr())];
    let mut acl: *mut ACL = std::ptr::null_mut();
    // SAFETY: entries живут до конца вызова; acl освобождается LocalFree ниже.
    let rc = unsafe { SetEntriesInAclW(entries.len() as u32, entries.as_ptr(), std::ptr::null(), &mut acl) };
    if rc != ERROR_SUCCESS {
        return Err(std::io::Error::from_raw_os_error(rc as i32));
    }
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    // SAFETY: wide нуль-терминирован, acl получен от SetEntriesInAclW.
    let rc = unsafe {
        SetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            acl,
            std::ptr::null(),
        )
    };
    // SAFETY: acl выделен SetEntriesInAclW через LocalAlloc.
    unsafe { LocalFree(acl.cast()) };
    if rc != ERROR_SUCCESS {
        return Err(std::io::Error::from_raw_os_error(rc as i32));
    }
    Ok(())
}

/// TOKEN_USER текущего процесса в owned-буфере (SID лежит внутри него).
fn current_user_sid() -> std::io::Result<Vec<u8>> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: псевдодескриптор процесса, token закрывается ниже.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut len = 0u32;
    // SAFETY: первый вызов узнаёт размер буфера.
    unsafe { GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut len) };
    let mut buf = vec![0u8; len.max(std::mem::size_of::<TOKEN_USER>() as u32) as usize];
    // SAFETY: буфер длины len.
    let ok = unsafe { GetTokenInformation(token, TokenUser, buf.as_mut_ptr().cast(), len, &mut len) };
    // SAFETY: token открыт выше.
    unsafe { CloseHandle(token) };
    if ok == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(buf)
}

fn user_sid_ptr(buf: &mut [u8]) -> *mut u8 {
    // SAFETY: buf заполнен GetTokenInformation(TokenUser); Sid указывает внутрь того же буфера.
    unsafe { std::ptr::read_unaligned(buf.as_ptr().cast::<TOKEN_USER>()).User.Sid.cast() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_gets_protected_owner_only_acl() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("key");
        std::fs::write(&p, b"K").unwrap();
        owner_only(&p).unwrap();
        let out = std::process::Command::new("icacls").arg(&p).output().unwrap();
        let text = String::from_utf8_lossy(&out.stdout);
        // (I) — унаследованная запись: после защиты DACL их нет; записей ровно две (пользователь и SYSTEM).
        assert!(!text.contains("(I)"), "{text}");
        assert_eq!(text.matches(":(F)").count(), 2, "{text}");
        assert_eq!(std::fs::read(&p).unwrap(), b"K", "владелец по-прежнему читает");
    }
}
