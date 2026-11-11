//! x86sim-mcp: a small MCP server (JSON-RPC 2.0 over stdio, one message per line) for the x86Sim arm64 simulator:
//! feature toggles (list / get / set / preset), sim control (status / start / stop / restart to apply) and the AOT
//! image status. Uses x86sim-core like the CLI and the GUI.
//!
//! Register it with an MCP client, e.g. `claude mcp add x86sim -- /path/to/x86sim-mcp`.
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use x86sim_core::{aot, apps, features, instance, sim};

fn tools() -> Value {
    let phone = json!({"type": "string", "description": "the phone: its name (as in the hub, e.g. \"QA\"), folder (device-a64-qa) or path. Default: the only running phone, else the configured one"});
    json!([
        {"name": "phones_list", "description": "Every phone, as the hub shows it: name, model, iOS version and whether it is installed, state (off / starting / running / stopping), home screen reached, memory (MB), CPU %, processes, uptime.",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "sim_status", "description": "Same as phones_list (kept for older clients).",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "features_list", "description": "List a phone's optional features: id, title, on/off, default, measured memory cost (MB) and whether it is paid every boot or only when used. Changes apply at the next boot.",
         "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "feature_get", "description": "Whether one feature is on.",
         "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "phone": phone}, "required": ["id"]}},
        {"name": "feature_set", "description": "Turn a feature on or off (wallpaper, spotlight, keyboard, siri, maps, photos, files, wallet, health, widgets). Applies at the next boot: call sim_restart.",
         "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "enabled": {"type": "boolean"}, "phone": phone}, "required": ["id", "enabled"]}},
        {"name": "features_preset", "description": "Apply a preset: full (the default set), lean, minimal. Applies at the next boot.",
         "inputSchema": {"type": "object", "properties": {"name": {"type": "string", "enum": ["full", "lean", "minimal"]}, "phone": phone}, "required": ["name"]}},
        {"name": "sim_devices", "description": "Phones (folder, label with phone model, iOS), the phone models a new phone can be and the installed iOS versions.",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "sim_add_device", "description": "Make a new phone of a model (see sim_devices models), optional name and version (ios, e.g. \"27.2\": iOS for an iPhone or iPad, tvOS for an Apple TV, watchOS for an Apple Watch, or a build such as \"24B91016s\"; see sim_devices runtimes; a model with a runtime of its own, the iPhone Duo's 24B91016s, gets that one). Start it with sim_start phone=<name>. Its first start can take a few minutes.",
         "inputSchema": {"type": "object", "properties": {"model": {"type": "string"}, "name": {"type": "string"}, "ios": {"type": "string"}}, "required": ["model"]}},
        {"name": "sim_start", "description": "Start a phone (its own container, so other phones keep running). Returns at once; poll phones_list for state running.", "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "sim_fold", "description": "Fold or unfold a two-screen phone (iPhone Duo): open=true opens it flat (the large inner screen takes over), open=false closes it (the outer screen); or angle in degrees (0 closed .. 180 flat; SpringBoard swaps screens at 85). The hinge moves over ms (default 600) as a hand would.",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "open": {"type": "boolean"}, "angle": {"type": "number"}, "ms": {"type": "integer"}}}},
        {"name": "sim_stop", "description": "Stop a phone (only that phone).", "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "sim_restart", "description": "Restart a phone (stop, then start with its current features and the pre-translated code). Returns at once; poll phones_list.",
         "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "app_install", "description": "Install an iOS Simulator app (.app bundle built for arm64 iphonesimulator) on a running phone, as simctl install: installd installs it and the home screen shows its icon. Returns the bundle id.",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "path": {"type": "string", "description": "the .app directory on this machine"}}, "required": ["path"]}},
        {"name": "app_uninstall", "description": "Uninstall an app from a running phone (simctl uninstall).",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "bundle_id": {"type": "string"}}, "required": ["bundle_id"]}},
        {"name": "app_launch", "description": "Open an app on a running phone by bundle id (simctl launch); args are passed to the app. Returns the pid.",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "bundle_id": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}}}, "required": ["bundle_id"]}},
        {"name": "app_list", "description": "Installed apps on a running phone (simctl listapps).", "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "aot_status", "description": "Pre-translated code of a phone's iOS version: parts up to date / stale (with reasons) / missing, and the translator's codegen version.",
         "inputSchema": {"type": "object", "properties": {"phone": phone}}}
    ])
}

/// The phone a call is about: phone / device argument, else the only running phone, else the configured one.
fn phone_of(a: &Value, cfg: &aot::Config) -> anyhow::Result<instance::Instance> {
    let key = a["phone"].as_str().or(a["device"].as_str());
    if let Some(k) = key {
        return instance::find(k).ok_or_else(|| {
            anyhow::anyhow!("no phone {k:?} (phones: {})", instance::list().iter().map(|i| i.name.clone()).collect::<Vec<_>>().join(", "))
        });
    }
    let running: Vec<_> = instance::summaries(0).into_iter().filter(|s| s.state != "off").collect();
    if running.len() == 1 {
        return instance::find(&running[0].id).ok_or_else(|| anyhow::anyhow!("phone vanished"));
    }
    let d = cfg.device.clone().ok_or_else(|| anyhow::anyhow!("say which phone (phone: name)"))?;
    Ok(instance::load(&d))
}

fn call(name: &str, a: &Value) -> anyhow::Result<Value> {
    let cfg = aot::Paths::new(&aot::Paths::default_jc()).load_config();
    if matches!(name, "phones_list" | "sim_status") {
        return Ok(json!({"phones": instance::summaries(1000)}));
    }
    if name == "sim_devices" {
        return Ok(json!({"devices": instance::list().into_iter().map(|i| json!({"name": i.name, "id": i.id, "label": format!("{} · {}", i.model, i.name), "path": i.dir, "ios": i.ios, "installed": i.runtime_present})).collect::<Vec<_>>(),
                         "models": sim::models().into_iter().map(|m| m.0).collect::<Vec<_>>(),
                         "runtimes": sim::runtimes().into_iter().map(|r| r.0).collect::<Vec<_>>()}));
    }
    if name == "sim_add_device" {
        let want = a["ios"].as_str().unwrap_or("27.2");
        // Models 2: a runtime limited to some models (iOS 27.2 24B91016s: iPhone Duo only) is taken for those models
        // first and never for others
        let model = a["model"].as_str().unwrap_or("");
        let model_id = sim::models().into_iter().find(|m| m.0 == model || m.1 == model).map(|m| m.1).unwrap_or_default();
        // Platforms 1: only runtimes of the model's platform (an Apple TV takes tvOS, an Apple Watch watchOS)
        let pname = sim::platform_name(sim::model_platform(&model_id));
        let cands: Vec<_> = sim::runtimes()
            .into_iter()
            .filter(|r| r.0.starts_with(&format!("{pname} ")))
            .filter(|r| r.0.starts_with(&format!("{pname} {want} ")) || r.0.contains(want))
            .filter(|r| sim::runtime_allows(&r.1, &model_id))
            .collect();
        let rt = cands
            .iter()
            .find(|r| !sim::runtime_restricted_to(&r.1).is_empty())
            .or(cands.first())
            .map(|r| r.1.clone())
            .ok_or_else(|| anyhow::anyhow!("no {pname} {want} installed for {model} (see sim_devices runtimes)"))?;
        return Ok(json!({"device": sim::create_device(a["model"].as_str().unwrap_or(""), a["name"].as_str().unwrap_or(""), &rt)?}));
    }
    let inst = phone_of(a, &cfg)?;
    let device = inst.dir.clone();
    Ok(match name {
        "features_list" => json!({"phone": inst.name, "preset": features::preset_of(&features::load(&device)), "features": features::list(&device)}),
        "feature_get" => {
            let id = a["id"].as_str().unwrap_or("");
            json!({"id": id, "enabled": features::load(&device).enabled(id)})
        }
        "feature_set" => {
            let id = a["id"].as_str().unwrap_or("");
            let on = a["enabled"].as_bool().ok_or_else(|| anyhow::anyhow!("enabled: boolean required"))?;
            features::set(&device, id, on)?;
            json!({"phone": inst.name, "id": id, "enabled": on, "note": "applies at the next boot (sim_restart)"})
        }
        "features_preset" => {
            let n = a["name"].as_str().unwrap_or("");
            features::apply_preset(&device, n)?;
            json!({"phone": inst.name, "preset": n, "features": features::list(&device), "note": "applies at the next boot (sim_restart)"})
        }
        "app_install" => json!({"phone": inst.name, "installed": apps::install(&inst, std::path::Path::new(a["path"].as_str().unwrap_or("")))?}),
        "app_uninstall" => json!({"phone": inst.name, "answer": apps::uninstall(&inst, a["bundle_id"].as_str().unwrap_or(""))?}),
        "app_launch" => {
            let args: Vec<String> = a["args"].as_array().map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            json!({"phone": inst.name, "answer": apps::launch(&inst, a["bundle_id"].as_str().unwrap_or(""), &args)?})
        }
        "app_list" => json!({"phone": inst.name, "answer": apps::list(&inst)?}),
        "sim_restart" => json!({"phone": inst.name, "restarting": true, "pid": sim::restart(&device)?}),
        "sim_start" => json!({"phone": inst.name, "starting": true, "pid": sim::start(&device)?}),
        "sim_fold" => {
            anyhow::ensure!(inst.inner.is_some(), "{} has one screen", inst.name);
            let deg = a["angle"].as_f64().unwrap_or(if a["open"].as_bool().unwrap_or(true) { 180.0 } else { 0.0 }).clamp(0.0, 180.0);
            let ms = a["ms"].as_u64().unwrap_or(600) as u32;
            x86sim_core::hid::Hid::new(&inst.sock).hinge(deg, ms);
            std::thread::sleep(std::time::Duration::from_millis(ms as u64 + 300));
            json!({"phone": inst.name, "hinge": inst.hinge(), "screen": if inst.inner_active() { "inner" } else { "outer" }})
        }
        "sim_stop" => {
            sim::stop(&device)?;
            json!({"phone": inst.name, "stopped": true})
        }
        "aot_status" => {
            // the phone's iOS version decides the image and its cache dir
            let rt = sim::device_runtime(&device);
            let p = aot::Paths::new(&sim::jc_for(&rt));
            let mut cfg = p.load_config();
            cfg.runtime_root = rt;
            cfg.device = Some(device.clone());
            let st = aot::plan(&p, &cfg)?.status(&p);
            let attention: Vec<_> = st.chunks.iter().filter(|c| c.state != "up-to-date").take(50).collect();
            json!({"phone": inst.name, "ios": inst.ios, "image": st.image, "image_current": st.image_current, "total": st.total, "up_to_date": st.up_to_date,
                   "stale": st.stale, "missing": st.missing, "codegen": format!("{:#x}", st.codegen), "codegen_source": st.codegen_source, "need_rebuild": attention})
        }
        _ => anyhow::bail!("unknown tool {name}"),
    })
}

fn main() {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let Ok(req) = serde_json::from_str::<Value>(&line) else { continue };
        let id = req.get("id").cloned();
        let method = req["method"].as_str().unwrap_or("");
        let result: Result<Value, (i64, String)> = match method {
            "initialize" => Ok(json!({
                "protocolVersion": req["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "x86sim", "version": env!("CARGO_PKG_VERSION")}
            })),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({"tools": tools()})),
            "tools/call" => {
                let name = req["params"]["name"].as_str().unwrap_or("");
                let args = req["params"].get("arguments").cloned().unwrap_or(json!({}));
                Ok(match call(name, &args) {
                    Ok(v) => json!({"content": [{"type": "text", "text": serde_json::to_string_pretty(&v).unwrap_or_default()}], "structuredContent": v}),
                    Err(e) => json!({"content": [{"type": "text", "text": format!("{e:#}")}], "isError": true}),
                })
            }
            m if m.starts_with("notifications/") => continue,
            _ => Err((-32601, format!("method not found: {method}"))),
        };
        let Some(id) = id else { continue };
        let resp = match result {
            Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
            Err((c, m)) => json!({"jsonrpc": "2.0", "id": id, "error": {"code": c, "message": m}}),
        };
        let _ = writeln!(out, "{resp}");
        let _ = out.flush();
    }
}
