// Writes .wraith/rust again when what it's made from changes: Wraith's API, which comes with the wraith
// launcher, schemas/, or a schema of a plugin it depends on. WRAITH can point at another wraith.exe
use std::process::Command;

fn main() {
    let wraith = std::env::var("WRAITH").unwrap_or_else(|_| "wraith".into());
    match Command::new(&wraith).args(["sdk", "rust", "types"]).output() {
        Ok(out) if out.status.success() => {}
        _ => println!("cargo:warning=couldn't run {wraith} sdk rust types, so .wraith/rust is as it was"),
    }
    if let Ok(inputs) = std::fs::read_to_string(".wraith/rust/inputs.txt") {
        for input in inputs.lines() {
            println!("cargo:rerun-if-changed={input}");
        }
    }
    println!("cargo:rerun-if-env-changed=WRAITH");
}
