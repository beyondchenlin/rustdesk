fn main() {
    #[cfg(windows)]
    {
        use std::io::Write;
        println!("cargo:rerun-if-changed=../../flutter/pubspec.yaml");
        let (product_version, numeric_version) = match client_product_version() {
            Ok(value) => value,
            Err(error) => {
                eprintln!("Cannot determine the BK Remote product version: {error}");
                std::process::exit(1);
            }
        };
        let mut res = winres::WindowsResource::new();
        res.set("FileVersion", &product_version)
            .set("ProductVersion", &product_version)
            .set_version_info(winres::VersionInfo::FILEVERSION, numeric_version)
            .set_version_info(winres::VersionInfo::PRODUCTVERSION, numeric_version);
        res.set_icon("../../res/icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("../../res/manifest.xml");
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}

#[cfg(windows)]
fn client_product_version() -> Result<(String, u64), String> {
    let spec = std::fs::read_to_string("../../flutter/pubspec.yaml")
        .map_err(|error| error.to_string())?;
    let version = spec
        .lines()
        .find_map(|line| line.strip_prefix("version:"))
        .ok_or("The application version is missing")?
        .trim();
    let (name, build) = version
        .split_once('+')
        .ok_or("The application version must include its build number")?;
    let parts: Vec<_> = name.split('.').chain(std::iter::once(build)).collect();
    if parts.len() != 4 {
        return Err("The Windows product version requires four numeric components".into());
    }
    let mut numeric = 0_u64;
    for part in parts {
        let value = part
            .parse::<u16>()
            .map_err(|_| "The Windows product version component is out of range")?;
        numeric = (numeric << 16) | u64::from(value);
    }
    Ok((version.to_owned(), numeric))
}
