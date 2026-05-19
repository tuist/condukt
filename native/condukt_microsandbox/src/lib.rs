//! Rustler NIF wrapping microsandbox so Condukt can run a session inside a
//! microVM-backed sandbox while preserving the generic `Condukt.Sandbox`
//! contract for tools.

use microsandbox::{MicrosandboxError, Sandbox as MicroSandbox};
use rustler::{Atom, Binary, Env, NifMap, NifResult, NifUnitEnum, ResourceArc};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;
use tokio::runtime::Runtime;

mod atoms {
    rustler::atoms! {
        ok,
    }
}

pub struct Session {
    runtime: Mutex<Runtime>,
    sandbox: Mutex<Option<MicroSandbox>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Session {}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum MountMode {
    Readonly,
    Readwrite,
}

#[derive(NifMap)]
pub struct MountSpec {
    pub host_path: String,
    pub guest_path: String,
    pub mode: MountMode,
}

#[derive(NifMap)]
pub struct SessionConfig {
    pub name: String,
    pub image: String,
    pub cpus: u8,
    pub memory_mib: u32,
    pub cwd: String,
    pub shell: String,
    pub env: Vec<(String, String)>,
    pub mounts: Vec<MountSpec>,
    pub replace_existing: bool,
}

#[derive(NifMap)]
pub struct ExecResult {
    pub output: String,
    pub exit_code: i32,
}

fn build_runtime() -> Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("failed to build microsandbox tokio runtime")
}

#[rustler::nif(schedule = "DirtyIo")]
fn new_session(config: SessionConfig) -> NifResult<Result<ResourceArc<Session>, String>> {
    let runtime = build_runtime();
    let sandbox = {
        let builder = build_builder(config);
        match runtime.block_on(async move { builder.create().await }) {
            Ok(sandbox) => sandbox,
            Err(err) => return Ok(Err(label_for_error(err))),
        }
    };

    Ok(Ok(ResourceArc::new(Session {
        runtime: Mutex::new(runtime),
        sandbox: Mutex::new(Some(sandbox)),
    })))
}

#[rustler::nif(schedule = "DirtyIo")]
fn shutdown(session: ResourceArc<Session>) -> Atom {
    let sandbox = take_sandbox(&session);

    if let Some(sandbox) = sandbox
        && let Ok(runtime) = session.runtime.lock()
    {
        let _ = runtime.block_on(async move { sandbox.stop_and_wait().await });
    }

    atoms::ok()
}

#[rustler::nif(schedule = "DirtyIo")]
fn exec(
    session: ResourceArc<Session>,
    shell: String,
    command: String,
    cwd: String,
    env: Vec<(String, String)>,
    timeout_ms: Option<u64>,
) -> NifResult<Result<ExecResult, String>> {
    let sandbox = clone_sandbox(&session)?;
    let timeout = timeout_ms.map(Duration::from_millis);
    let runtime = session.runtime.lock().map_err(|_| poisoned())?;

    let result = runtime.block_on(async move {
        sandbox
            .exec_with(shell, |exec| {
                let exec = exec.arg("-c").arg(command).cwd(cwd);
                let exec = env.into_iter().fold(exec, |acc, (key, value)| acc.env(key, value));

                match timeout {
                    Some(duration) => exec.timeout(duration),
                    None => exec,
                }
            })
            .await
    });

    match result {
        Ok(output) => {
            let stdout = output.stdout().unwrap_or_default();
            let stderr = output.stderr().unwrap_or_default();

            Ok(Ok(ExecResult {
                output: combine_output(&stdout, &stderr),
                exit_code: output.status().code,
            }))
        }
        Err(err) => Ok(Err(label_for_error(err))),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_file<'a>(
    env: Env<'a>,
    session: ResourceArc<Session>,
    path: String,
) -> NifResult<Result<Binary<'a>, String>> {
    let sandbox = clone_sandbox(&session)?;
    let runtime = session.runtime.lock().map_err(|_| poisoned())?;

    let result = runtime.block_on(async move { sandbox.fs().read(&path).await });

    match result {
        Ok(bytes) => {
            let mut owned = rustler::OwnedBinary::new(bytes.len()).ok_or_else(|| {
                rustler::Error::Term(Box::new("failed to allocate binary".to_string()))
            })?;
            owned.as_mut_slice().copy_from_slice(&bytes);
            Ok(Ok(Binary::from_owned(owned, env)))
        }
        Err(err) => Ok(Err(label_for_error(err))),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn write_file(
    session: ResourceArc<Session>,
    path: String,
    content: Binary,
) -> NifResult<Result<Atom, String>> {
    let sandbox = clone_sandbox(&session)?;
    let runtime = session.runtime.lock().map_err(|_| poisoned())?;
    let bytes = content.as_slice().to_vec();

    let result = runtime.block_on(async move {
        if let Some(parent) = Path::new(&path).parent()
            && !parent.as_os_str().is_empty()
        {
            let parent = parent.to_string_lossy().into_owned();
            sandbox.fs().mkdir(&parent).await?;
        }

        sandbox.fs().write(&path, &bytes).await
    });

    match result {
        Ok(()) => Ok(Ok(atoms::ok())),
        Err(err) => Ok(Err(label_for_error(err))),
    }
}

fn build_builder(config: SessionConfig) -> microsandbox::sandbox::SandboxBuilder {
    let mut builder = MicroSandbox::builder(config.name)
        .image(config.image)
        .cpus(config.cpus)
        .memory(config.memory_mib)
        .workdir(config.cwd)
        .shell(config.shell);

    if config.replace_existing {
        builder = builder.replace();
    }

    for (key, value) in config.env {
        builder = builder.env(key, value);
    }

    for mount in config.mounts {
        let host_path = PathBuf::from(mount.host_path);
        let guest_path = mount.guest_path;
        let readonly = matches!(mount.mode, MountMode::Readonly);

        builder = builder.volume(guest_path, move |volume| {
            let volume = volume.bind(host_path);
            if readonly { volume.readonly() } else { volume }
        });
    }

    builder
}

fn clone_sandbox(session: &ResourceArc<Session>) -> NifResult<MicroSandbox> {
    let guard = session.sandbox.lock().map_err(|_| poisoned())?;
    guard
        .as_ref()
        .cloned()
        .ok_or_else(|| rustler::Error::Term(Box::new("sandbox closed".to_string())))
}

fn take_sandbox(session: &ResourceArc<Session>) -> Option<MicroSandbox> {
    session
        .sandbox
        .lock()
        .ok()
        .and_then(|mut guard| guard.take())
}

fn label_for_error(err: MicrosandboxError) -> String {
    match err {
        MicrosandboxError::ExecTimeout(_) => "timeout".to_string(),
        MicrosandboxError::Io(io) => label_for_io(&io),
        MicrosandboxError::SandboxFs(message) => label_for_message(&message),
        other => label_for_message(&other.to_string()),
    }
}

fn label_for_io(err: &std::io::Error) -> String {
    match err.kind() {
        std::io::ErrorKind::NotFound => "enoent".to_string(),
        std::io::ErrorKind::PermissionDenied => "eacces".to_string(),
        std::io::ErrorKind::AlreadyExists => "eexist".to_string(),
        std::io::ErrorKind::IsADirectory => "eisdir".to_string(),
        _ => err.to_string(),
    }
}

fn label_for_message(message: &str) -> String {
    let lower = message.to_lowercase();

    if lower.contains("no such file") || lower.contains("not found") {
        "enoent".to_string()
    } else if lower.contains("permission denied") {
        "eacces".to_string()
    } else if lower.contains("already exists") {
        "eexist".to_string()
    } else if lower.contains("is a directory") {
        "eisdir".to_string()
    } else {
        message.to_string()
    }
}

fn combine_output(stdout: &str, stderr: &str) -> String {
    if stderr.is_empty() {
        stdout.to_string()
    } else if stdout.is_empty() {
        stderr.to_string()
    } else {
        format!("{stdout}{stderr}")
    }
}

fn poisoned() -> rustler::Error {
    rustler::Error::Term(Box::new("microsandbox session lock poisoned".to_string()))
}

rustler::init!("Elixir.Condukt.Microsandbox.NIF");
