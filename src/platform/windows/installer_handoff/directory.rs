#[cfg(test)]
#[path = "directory/tests/security.rs"]
mod security_tests;

use super::super::{
    installer_shell::{get_known_folder, get_system_executable, path_for_cmd_environment},
    wide_string,
};
use hbb_common::{anyhow::anyhow, bail, log, ResultType};
use std::{
    fs, mem,
    os::windows::fs::MetadataExt,
    path::{Path, PathBuf},
};
use windows::{
    core::{w, PCWSTR},
    Win32::{
        Foundation::{LocalFree, HLOCAL},
        Security::{
            Authorization::{
                ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
            },
            PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES,
        },
        Storage::FileSystem::{CreateDirectoryW, FILE_ATTRIBUTE_REPARSE_POINT},
        UI::Shell::FOLDERID_ProgramData,
    },
};

pub(in crate::platform::windows) fn path() -> ResultType<PathBuf> {
    let system = get_system_executable("")?;
    let windows = system
        .parent()
        .ok_or_else(|| anyhow!("System directory has no parent"))?;
    let temporary = windows.join("Temp");
    let parent = temporary_parent(&temporary)?;
    Ok(parent.join(format!(
        "rustdesk-install-{}",
        uuid::Uuid::new_v4().simple()
    )))
}

fn temporary_parent(temporary: &Path) -> ResultType<PathBuf> {
    let parent = if has_reparse_parent(temporary)? {
        let fallback = get_known_folder(&FOLDERID_ProgramData)?;
        if has_reparse_parent(&fallback)? {
            bail!(
                "Installer fallback directory contains a reparse point: {}",
                fallback.display()
            );
        }
        log::warn!(
            "Installer temporary directory contains a reparse point; using {} instead of {}",
            fallback.display(),
            temporary.display()
        );
        fallback
    } else {
        temporary.to_owned()
    };
    if !supports_acls(&parent).map_err(|error| {
        anyhow!(
            "Failed to inspect installer volume {}: {error}",
            parent.display()
        )
    })? {
        bail!(
            "Installer temporary volume does not support persistent ACLs: {}",
            parent.display()
        );
    }
    Ok(parent)
}

fn has_reparse_parent(path: &Path) -> ResultType<bool> {
    for parent in path.ancestors() {
        let metadata = fs::symlink_metadata(parent).map_err(|err| {
            anyhow!(
                "Failed to inspect installer temporary parent {}: {err}",
                parent.display()
            )
        })?;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
            return Ok(true);
        }
        if !metadata.is_dir() {
            bail!(
                "Installer temporary parent is not a regular directory: {}",
                parent.display()
            );
        }
    }
    Ok(false)
}

fn supports_acls(path: &Path) -> ResultType<bool> {
    use std::os::windows::{fs::OpenOptionsExt, io::AsRawHandle};
    use windows::Win32::{
        Foundation::HANDLE,
        Storage::FileSystem::{
            GetVolumeInformationByHandleW, FILE_FLAG_BACKUP_SEMANTICS, FILE_READ_ATTRIBUTES,
            FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
        },
    };

    let directory = fs::OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES.0)
        .share_mode((FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE).0)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS.0)
        .open(path)?;
    let mut flags = 0;
    unsafe {
        GetVolumeInformationByHandleW(
            HANDLE(directory.as_raw_handle()),
            None,
            None,
            None,
            Some(&mut flags),
            None,
        )?;
    }
    Ok(flags & winapi::um::winnt::FILE_PERSISTENT_ACLS != 0)
}

pub(super) fn create(path: &Path) -> ResultType<()> {
    let wide_path = wide_string(path_for_cmd_environment(path)?);
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    // OWNER RIGHTS removes the ordinary creator's implicit WRITE_DAC permission.
    // The owner can inspect the ACL, but only Administrators/SYSTEM can modify contents.
    // https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-special-identities-groups#owner-rights
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            w!("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;RC;;;OW)"),
            SDDL_REVISION_1,
            &mut descriptor,
            None,
        )?;
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: false.into(),
    };
    let result = unsafe { CreateDirectoryW(PCWSTR(wide_path.as_ptr()), Some(&attributes)) };
    unsafe { LocalFree(Some(HLOCAL(descriptor.0))) };
    result.map_err(|err| {
        anyhow!(
            "Failed to create protected installer directory {}: {err}",
            path.display()
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use winapi::um::winnt::MAXIMUM_ALLOWED;
    use windows::{
        core::{Owned, BOOL},
        Win32::{
            Foundation::{ERROR_ACCESS_DENIED, HANDLE},
            Security::{
                AccessCheck,
                Authorization::{GetNamedSecurityInfoW, SE_FILE_OBJECT},
                DuplicateToken, GetSecurityDescriptorLength, SecurityImpersonation,
                DACL_SECURITY_INFORMATION, GENERIC_MAPPING,
                GROUP_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, PRIVILEGE_SET,
                TOKEN_DUPLICATE, TOKEN_QUERY,
            },
            Storage::FileSystem::{
                FILE_ALL_ACCESS, FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
                READ_CONTROL,
            },
            System::Threading::{GetCurrentProcess, OpenProcessToken},
        },
    };

    fn create_cleanup_parent(path: &Path) -> ResultType<()> {
        let wide_path = wide_string(path_for_cmd_environment(path)?);
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                w!("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;OW)"),
                SDDL_REVISION_1,
                &mut descriptor,
                None,
            )?;
        }
        let attributes = SECURITY_ATTRIBUTES {
            nLength: mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor.0,
            bInheritHandle: false.into(),
        };
        let result = unsafe { CreateDirectoryW(PCWSTR(wide_path.as_ptr()), Some(&attributes)) };
        unsafe { LocalFree(Some(HLOCAL(descriptor.0))) };
        result?;
        Ok(())
    }

    #[test]
    fn protected_directory_enforces_creator_permissions() {
        let elevated =
            super::super::super::is_elevated(None).expect("creator elevation should be available");
        let parent = std::env::temp_dir().join(format!(
            "rustdesk_installer_acl_{}",
            uuid::Uuid::new_v4().simple()
        ));
        create_cleanup_parent(&parent).expect("isolated fixture parent should be created");
        let directory = parent.join("protected");
        create(&directory).expect("production directory creation should succeed");
        let descriptor_before =
            security_descriptor_bytes(&directory).expect("security descriptor should be readable");
        let access =
            creator_directory_access(&directory).expect("created directory access should be checked");
        let expected = if elevated {
            FILE_ALL_ACCESS
        } else {
            READ_CONTROL
        };
        assert_eq!(
            access,
            (true, expected.0),
            "only elevated administrators may modify the protected directory"
        );

        if elevated {
            fs::remove_dir(&directory).expect("elevated creator should remove the protected fixture");
            fs::remove_dir(&parent).expect("elevated creator should remove its fixture parent");
        } else {
            // A regular creator intentionally cannot delete this protected handoff
            // directory. Test the denial instead of requiring forbidden teardown.
            let error = fs::remove_dir(&directory)
                .expect_err("an unelevated creator must not remove the protected directory");
            assert_eq!(
                error.raw_os_error(),
                Some(ERROR_ACCESS_DENIED.0 as i32),
                "only the explicit protected-directory access denial is expected"
            );
            assert_eq!(
                creator_directory_access(&directory)
                    .expect("denied deletion must preserve readable permissions"),
                access,
                "denied deletion must preserve the creator's READ_CONTROL access"
            );
            let descriptor_after = security_descriptor_bytes(&directory)
                .expect("denied deletion must preserve the security descriptor");
            assert_eq!(
                descriptor_after, descriptor_before,
                "denied deletion must not change the actual security descriptor"
            );
            let record = parent.with_extension("retained.json");
            let mut evidence = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&record)
                .expect("retained fixture evidence must be created without overwriting a file");
            serde_json::to_writer_pretty(
                &mut evidence,
                &serde_json::json!({
                    "test": "protected_directory_enforces_creator_permissions",
                    "parent": parent,
                    "protected_directory": directory,
                    "caller_is_elevated": false,
                    "delete_error_code": error.raw_os_error(),
                    "access_check_allowed": access.0,
                    "maximum_allowed": access.1,
                    "security_descriptor_unchanged": true,
                    "security_descriptor_bytes": descriptor_before,
                    "cleanup_status": "retained_for_explicit_administrator_cleanup",
                    "scope": "New isolated test fixture only; no production permissions changed"
                }),
            )
            .expect("retained fixture evidence must be serialized");
            evidence.sync_all().expect("retained fixture evidence must be saved");
            eprintln!(
                "Protected test fixture retained for administrator cleanup: {}",
                record.display()
            );
        }
    }

    fn security_descriptor_bytes(path: &Path) -> ResultType<Vec<u8>> {
        let wide_path = wide_string(path_for_cmd_environment(path)?);
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        unsafe {
            GetNamedSecurityInfoW(
                PCWSTR(wide_path.as_ptr()),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                None,
                None,
                None,
                None,
                &mut descriptor,
            )
            .ok()?;
        }
        let _descriptor = unsafe { Owned::new(HLOCAL(descriptor.0)) };
        let length = unsafe { GetSecurityDescriptorLength(descriptor) } as usize;
        if length == 0 {
            return Err(anyhow!("The protected test directory security descriptor is empty"));
        }
        Ok(unsafe { std::slice::from_raw_parts(descriptor.0.cast::<u8>(), length) }.to_vec())
    }

    fn creator_directory_access(path: &Path) -> ResultType<(bool, u32)> {
        let wide_path = wide_string(path_for_cmd_environment(path)?);
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        unsafe {
            GetNamedSecurityInfoW(
                PCWSTR(wide_path.as_ptr()),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                None,
                None,
                None,
                None,
                &mut descriptor,
            )
            .ok()?;
        }
        let _descriptor = unsafe { Owned::new(HLOCAL(descriptor.0)) };
        let token = creator_impersonation_token()?;
        let mapping = GENERIC_MAPPING {
            GenericRead: FILE_GENERIC_READ.0,
            GenericWrite: FILE_GENERIC_WRITE.0,
            GenericExecute: FILE_GENERIC_EXECUTE.0,
            GenericAll: FILE_ALL_ACCESS.0,
        };
        let mut privileges = PRIVILEGE_SET::default();
        let mut privilege_size = mem::size_of::<PRIVILEGE_SET>() as u32;
        let mut granted = 0;
        let mut allowed = BOOL::default();
        unsafe {
            AccessCheck(
                descriptor,
                *token,
                MAXIMUM_ALLOWED,
                &mapping,
                Some(&mut privileges),
                &mut privilege_size,
                &mut granted,
                &mut allowed,
            )?;
        }
        Ok((allowed.as_bool(), granted))
    }

    fn creator_impersonation_token() -> ResultType<Owned<HANDLE>> {
        let mut token = HANDLE::default();
        unsafe {
            OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_QUERY | TOKEN_DUPLICATE,
                &mut token,
            )?
        };
        let token = unsafe { Owned::new(token) };
        let mut impersonation = HANDLE::default();
        unsafe { DuplicateToken(*token, SecurityImpersonation, &mut impersonation)? };
        Ok(unsafe { Owned::new(impersonation) })
    }
}
