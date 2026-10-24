mod app;
mod config;
mod error;
mod immich;
mod library;
mod media;
mod methods;
mod paths;
mod rpc;
mod secrets;
mod sync;

use std::process::ExitCode;

fn usage() -> ExitCode {
    eprintln!("usage: omamich <serve|version|check>");
    eprintln!("  serve    run the backend for the Omarchy plugin (JSON-RPC on stdio)");
    eprintln!("  version  print the version and API revision");
    eprintln!("  check    test the saved server and key");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_default();
    match command.as_str() {
        "version" | "--version" | "-V" => {
            println!("omamich {} (api {})", env!("CARGO_PKG_VERSION"), methods::API_VERSION);
            ExitCode::SUCCESS
        }
        "serve" => run(serve()),
        "check" => run(check()),
        _ => usage(),
    }
}

fn run(future: impl std::future::Future<Output = ExitCode>) -> ExitCode {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .expect("tokio runtime");
    runtime.block_on(future)
}

async fn serve() -> ExitCode {
    let (notifier, out) = rpc::Notifier::channel();
    let app = match app::App::start(paths::Paths::from_env(), notifier).await {
        Ok(app) => app,
        Err(err) => {
            eprintln!("omamich: could not start: {err}");
            return ExitCode::FAILURE;
        }
    };
    tokio::select! {
        _ = rpc::serve(app, out) => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    ExitCode::SUCCESS
}

async fn check() -> ExitCode {
    let paths = paths::Paths::from_env();
    let settings = config::Settings::load(&paths);
    let Some(key) = secrets::load(&paths).await else {
        eprintln!("No API key saved. Open Omamich and add one in Settings.");
        return ExitCode::FAILURE;
    };
    let client = immich::Immich::new();
    let mut ok = false;
    for url in [&settings.server_url, &settings.external_url] {
        if url.is_empty() {
            continue;
        }
        match client.probe(url, &key).await {
            Ok(info) => {
                ok = true;
                println!("{url}: Immich {} as {}", info["version"].as_str().unwrap_or("?"), info["user"]["email"].as_str().unwrap_or("?"));
            }
            Err(err) => println!("{url}: {err}"),
        }
    }
    if ok { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
