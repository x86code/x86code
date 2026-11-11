//! x86sim-aot: the chunked AOT image, feature toggles and sim control from the command line.
//!
//!   x86sim-aot [--jc DIR] status [--json] [--all]       per-chunk state: up to date / stale (why) / missing
//!   x86sim-aot [--jc DIR] update [--workers N]          rebuild only stale and missing chunks, then assemble
//!   x86sim-aot [--jc DIR] build [--full] [--workers N] [--only NAME]
//!   x86sim-aot [--jc DIR] measure [--workers N]         every chunk of the scope, unlimited, sizes only
//!   x86sim-aot [--jc DIR] config [KEY VALUE]            scope (hot|loaded|all), budget_mb, follow_features, training
//!   x86sim-aot features list|get ID|set ID on|off|preset full|lean|minimal [--device DIR]
//!   x86sim-aot sim status|start|stop|restart|show [--device DIR|NAME]   status: every phone
//!   x86sim-aot setup check|install-darling|link-runtime DIR|done [--json]   the launcher's setup steps (docs/RELEASE.md)
use anyhow::{bail, Context, Result};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use x86sim_core::{aot, features, instance, sim};

static CANCEL: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_: libc::c_int) {
    CANCEL.store(true, Ordering::Relaxed);
}

fn main() {
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL); // `| head` ends quietly
    }
    if let Err(e) = run() {
        eprintln!("x86sim-aot: {e:#}");
        std::process::exit(1);
    }
}

fn take(args: &mut Vec<String>, flag: &str) -> Option<String> {
    let i = args.iter().position(|a| a == flag)?;
    args.remove(i);
    (i < args.len()).then(|| args.remove(i))
}

fn has(args: &mut Vec<String>, flag: &str) -> bool {
    args.iter().position(|a| a == flag).map(|i| args.remove(i)).is_some()
}

fn fmt_s(s: f64) -> String {
    if s >= 60.0 {
        format!("{}m{:02}s", (s / 60.0) as u64, s as u64 % 60)
    } else {
        format!("{s:.0}s")
    }
}

fn run() -> Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    // a phone brings its iOS version, and with it the cache dir (27.0: the default one, others jc-<build>)
    // --device: a path, a folder (device-a64-qa) or a phone's name ("QA")
    // an existing path is made absolute: it ends up inside Darling under /Volumes/SystemRoot, where a relative
    // "var/device-a64" became "/Volumes/SystemRootvar/device-a64" and launchd_sim aborted on the missing plist
    let dev = take(&mut args, "--device").map(|d| if std::path::Path::new(&d).exists() { std::fs::canonicalize(&d).unwrap_or_else(|_| PathBuf::from(&d)) } else { instance::find(&d).map(|i| i.dir).unwrap_or_else(|| PathBuf::from(&d)) });
    let rt = dev.as_deref().map(sim::device_runtime);
    let jc = take(&mut args, "--jc").map(PathBuf::from).or_else(|| rt.as_deref().map(sim::jc_for)).unwrap_or_else(aot::Paths::default_jc);
    let p = aot::Paths::new(&jc);
    let mut cfg = p.load_config();
    if let (Some(d), Some(r)) = (dev, rt) {
        cfg.device = Some(d);
        cfg.runtime_root = r;
    }
    let json = has(&mut args, "--json");
    let cmd = if args.is_empty() { "status".to_string() } else { args.remove(0) };
    match cmd.as_str() {
        "status" => {
            let all = has(&mut args, "--all");
            let st = aot::plan(&p, &cfg)?.status(&p);
            if json {
                println!("{}", serde_json::to_string_pretty(&st)?);
                return Ok(());
            }
            println!("translator codegen {:#x} (from {:?})", st.codegen, st.codegen_source);
            println!("image {} ({})", st.image, if st.image_current { "current" } else if st.image_present { "present, not current" } else { "missing" });
            println!(
                "scope {} budget {} MB; {} chunks: {} up to date, {} stale, {} missing ({} libraries over budget stay lazy); training: {} profiles, {} hot blocks",
                st.scope, st.budget_mb, st.total, st.up_to_date, st.stale, st.missing, st.dropped, st.training_files, st.hot_blocks
            );
            let need = st.stale + st.missing;
            if need > 0 {
                println!("{need} of {} chunks need rebuilding (x86sim-aot update)", st.total);
            }
            for c in st.chunks.iter().filter(|c| all || c.state != "up-to-date") {
                println!("  {:10} {:6.1} MB  {}{}", c.state, c.slot_mb, c.name, if c.reasons.is_empty() { String::new() } else { format!("  [{}]", c.reasons.join("; ")) });
            }
        }
        "build" | "update" | "measure" => {
            if let Some(s) = take(&mut args, "--scope") {
                cfg.scope = s;
            }
            if let Some(b) = take(&mut args, "--budget") {
                cfg.budget_mb = b.parse()?;
            }
            let mut o = aot::BuildOpts::default();
            if let Some(w) = take(&mut args, "--workers") {
                o.workers = w.parse()?;
            }
            o.full = cmd == "build" && has(&mut args, "--full");
            o.measure = cmd == "measure";
            o.only = take(&mut args, "--only").map(|s| s.split(',').map(String::from).collect());
            o.force = has(&mut args, "--force");
            let flag = Arc::new(AtomicBool::new(false));
            o.cancel = flag.clone();
            unsafe {
                libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
                libc::signal(libc::SIGINT, on_signal as *const () as libc::sighandler_t);
            }
            std::thread::spawn(move || loop {
                if CANCEL.load(Ordering::Relaxed) {
                    flag.store(true, Ordering::Relaxed);
                }
                std::thread::sleep(std::time::Duration::from_millis(200));
            });
            let mut last = std::time::Instant::now() - std::time::Duration::from_secs(10);
            let r = aot::build(&p, &cfg, &o, &mut |pr| {
                if last.elapsed().as_secs() >= 5 || matches!(pr.state.as_str(), "done" | "error" | "cancelled" | "assembling") {
                    last = std::time::Instant::now();
                    if json {
                        println!("{}", serde_json::to_string(pr).unwrap_or_default());
                    } else {
                        println!(
                            "[{}] {} {}/{} chunks ({} skipped), {} blocks, {:.0} MB, {} elapsed{}{}",
                            pr.state,
                            pr.message,
                            pr.chunks_done,
                            pr.chunks_total,
                            pr.chunks_skipped,
                            pr.blocks,
                            pr.mb_written,
                            fmt_s(pr.elapsed_s),
                            pr.eta_s.map(|e| format!(", ETA {}", fmt_s(e))).unwrap_or_default(),
                            if pr.current.is_empty() { String::new() } else { format!(" — {}", pr.current.join(", ")) }
                        );
                    }
                }
            })?;
            if r.state != "done" {
                bail!("{}: {}", r.state, r.message);
            }
        }
        // export-training [--out FILE] [--merge FILE]... [DIR...]: the shipped training file from this cache dir's
        // profiles (and DIRs), with earlier training files folded in
        "export-training" => {
            let out = take(&mut args, "--out").map(PathBuf::from).or_else(|| aot::shipped_training(&p)).context("no output path")?;
            let mut merge = vec![];
            while let Some(f) = take(&mut args, "--merge") {
                merge.push(PathBuf::from(f));
            }
            let mut dirs: Vec<PathBuf> = args.iter().map(PathBuf::from).collect();
            dirs.push(p.jc.clone());
            let uuid = x86sim_core::dyldcache::Cache::open(&cfg.runtime_root)?.uuid_hex();
            let n = x86sim_core::hot::write_shipped(&dirs, &uuid, &out, &merge)?;
            println!("{n} blocks -> {} ({:.1} MB)", out.display(), std::fs::metadata(&out)?.len() as f64 / 1e6);
            return Ok(());
        }
        "config" => {
            if args.len() >= 2 {
                let (k, v) = (args[0].as_str(), args[1].clone());
                match k {
                    "scope" => cfg.scope = v,
                    "budget_mb" => cfg.budget_mb = v.parse()?,
                    "follow_features" => cfg.follow_features = v == "true" || v == "on" || v == "1",
                    "training" => cfg.training = v.split(',').map(PathBuf::from).collect(),
                    "runtime_root" => cfg.runtime_root = v.into(),
                    "device" => cfg.device = Some(v.into()),
                    _ => bail!("unknown config key {k}"),
                }
                p.save_config(&cfg)?;
            }
            println!("{}", serde_json::to_string_pretty(&cfg)?);
        }
        "features" => {
            let dev = cfg.device.clone().ok_or_else(|| anyhow::anyhow!("no device (--device DIR)"))?;
            let sub = if args.is_empty() { "list".to_string() } else { args.remove(0) };
            match sub.as_str() {
                "list" => {
                    let l = features::list(&dev);
                    if json {
                        println!("{}", serde_json::to_string_pretty(&l)?);
                    } else {
                        let prof = features::load(&dev);
                        println!("device {} (preset: {}); changes apply at the next boot", dev.display(), features::preset_of(&prof).unwrap_or("custom".into()));
                        for f in l {
                            println!(
                                "  [{}] {:10} ~{:4} MB ({})  {}{}",
                                if f.enabled { "x" } else { " " },
                                f.id,
                                f.cost_mb,
                                if f.when == "boot" { "every boot" } else { "when used" },
                                f.title,
                                if f.enabled != f.default { " (changed)" } else { "" }
                            );
                        }
                    }
                }
                "get" => {
                    let id = args.first().ok_or_else(|| anyhow::anyhow!("features get ID"))?;
                    println!("{}", if features::load(&dev).enabled(id) { "on" } else { "off" });
                }
                "set" => {
                    if args.len() < 2 {
                        bail!("features set ID on|off");
                    }
                    let on = matches!(args[1].as_str(), "on" | "true" | "1" | "yes");
                    features::set(&dev, &args[0], on)?;
                    println!("{} {} (restart the sim to apply)", args[0], if on { "on" } else { "off" });
                }
                "preset" => {
                    let name = args.first().ok_or_else(|| anyhow::anyhow!("features preset full|lean|minimal"))?;
                    features::apply_preset(&dev, name)?;
                    println!("preset {name} (restart the sim to apply)");
                }
                _ => bail!("features list|get|set|preset"),
            }
        }
        "setup" => {
            use x86sim_core::setup;
            let sub = if args.is_empty() { "check".to_string() } else { args.remove(0) };
            match sub.as_str() {
                "check" => {
                    let c = setup::checks();
                    if json {
                        println!("{}", serde_json::to_string_pretty(&c)?);
                    } else {
                        println!("x86Sim {} · data {}", setup::version(), aot::repo_root().display());
                        for k in &c {
                            println!("{:5} {:20} {}{}", format!("{:?}", k.level).to_lowercase(), k.name, k.detail, if k.fix.is_empty() { String::new() } else { format!("\n{:27}{}", "", k.fix) });
                        }
                        println!("setup needed: {}", setup::needed());
                    }
                }
                "install-darling" => {
                    setup::install_darling(&|s| eprintln!("{s}"))?;
                    println!("Darling installed in {}", setup::OPT_DARLING);
                }
                "link-runtime" => {
                    let d = args.first().ok_or_else(|| anyhow::anyhow!("setup link-runtime DIR"))?;
                    println!("runtimes/{}", setup::link_runtime(std::path::Path::new(d))?);
                }
                "done" => setup::mark_done()?,
                _ => bail!("setup check|install-darling|link-runtime DIR|done"),
            }
        }
        "sim" => {
            let dev = cfg.device.clone().ok_or_else(|| anyhow::anyhow!("no device (--device DIR)"))?;
            let sub = if args.is_empty() { "status".to_string() } else { args.remove(0) };
            // `sim stop var/device-a64-ram3` used to ignore the path and stop the --device default (the main phone)
            if matches!(sub.as_str(), "start" | "stop" | "restart") && !args.is_empty() {
                bail!("sim {sub}: unexpected argument {:?} (the phone is --device DIR)", args[0]);
            }
            match sub.as_str() {
                "status" => {
                    let all = instance::summaries(1000);
                    if json {
                        println!("{}", serde_json::to_string_pretty(&all)?);
                    } else {
                        for s in all {
                            let live = if s.state == "off" { String::new() } else { format!("  {:.0} MB  {:.0}% CPU  {} procs{}", s.memory_mb, s.cpu_pct, s.processes, if s.home { "  home" } else { "" }) };
                            println!("{:20} {:18} {:10} {:9}{}{}", s.name, s.model, s.ios, s.state, if s.installed { "" } else { "  (iOS not installed)" }, live);
                        }
                    }
                }
                "start" => println!("booting (pid {})", sim::start(&dev)?),
                "stop" => {
                    sim::stop(&dev)?;
                    println!("stopped");
                }
                "restart" => println!("restarting (pid {})", sim::restart(&dev)?),
                "show" => sim::show()?,
                _ => bail!("sim status|start|stop|restart|show"),
            }
        }
        _ => bail!("unknown command {cmd} (status, update, build, measure, config, features, sim)"),
    }
    Ok(())
}
