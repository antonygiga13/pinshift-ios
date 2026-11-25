use std::ffi::{CStr, CString, c_char};
use std::net::{IpAddr, SocketAddr};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use idevice::core_device_proxy::CoreDeviceProxy;
use idevice::dvt::location_simulation::LocationSimulationClient;
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::TcpProvider;
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::services::simulate_location::LocationSimulationService;
use idevice::tcp::adapter::Adapter;
use idevice::tcp::handle::AdapterHandle;
use idevice::{IdeviceService, RsdService};
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};

#[repr(C)]
pub struct LocBridgeResult {
    pub code: i32,
    pub message: *mut c_char,
}

impl LocBridgeResult {
    fn ok(msg: impl Into<String>) -> Self {
        Self {
            code: 0,
            message: into_c_string(msg.into()),
        }
    }

    fn err(code: i32, msg: impl Into<String>) -> Self {
        Self {
            code,
            message: into_c_string(msg.into()),
        }
    }
}

fn into_c_string(s: String) -> *mut c_char {
    let sanitized = s.replace('\0', " ");
    CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("unknown error").unwrap())
        .into_raw()
}

enum PairingKind {
    RemotePairing(RpPairingFile),
    Lockdown(PairingFile),
}

enum SessionCommand {
    Set {
        latitude: f64,
        longitude: f64,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Clear {
        reply: oneshot::Sender<Result<(), String>>,
    },
    Disconnect {
        reply: oneshot::Sender<()>,
    },
}

struct ActiveSession {
    tx: mpsc::Sender<SessionCommand>,
    connected: Arc<AtomicBool>,
}

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static SESSION: OnceLock<Mutex<Option<ActiveSession>>> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("pinshift-idevice")
            .thread_stack_size(4 * 1024 * 1024)
            .enable_all()
            .build()
            .expect("failed to initialize Tokio runtime")
    })
}

fn session_lock() -> &'static Mutex<Option<ActiveSession>> {
    SESSION.get_or_init(|| Mutex::new(None))
}

async fn run_dvt_loop(
    mut adapter: AdapterHandle,
    mut handshake: RsdHandshake,
    connected_label: String,
    mut rx: mpsc::Receiver<SessionCommand>,
    ready_tx: oneshot::Sender<Result<String, String>>,
    connected: Arc<AtomicBool>,
) {
    let mut remote_server = match RemoteServerClient::connect_rsd(&mut adapter, &mut handshake).await
    {
        Ok(client) => client,
        Err(e) => {
            let _ = ready_tx.send(Err(format!(
                "DVT RemoteServer non disponibile: {e}. Verifica che la Modalità Sviluppatore sia attiva e la Developer Disk Image montata."
            )));
            connected.store(false, Ordering::SeqCst);
            return;
        }
    };

    if let Err(e) = remote_server.read_message(0).await {
        let _ = ready_tx.send(Err(format!("DVT handshake iniziale fallito: {e}")));
        connected.store(false, Ordering::SeqCst);
        return;
    }

    let mut ls_client = match LocationSimulationClient::new(&mut remote_server).await {
        Ok(client) => client,
        Err(e) => {
            let _ = ready_tx.send(Err(format!(
                "Canale LocationSimulation non disponibile: {e}"
            )));
            connected.store(false, Ordering::SeqCst);
            return;
        }
    };

    connected.store(true, Ordering::SeqCst);
    let _ = ready_tx.send(Ok(connected_label));

    let mut active_coords: Option<(f64, f64)> = None;
    let mut keepalive = tokio::time::interval(Duration::from_secs(5));
    keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            cmd = rx.recv() => {
                match cmd {
                    Some(SessionCommand::Set { latitude, longitude, reply }) => {
                        match ls_client.set(latitude, longitude).await {
                            Ok(()) => {
                                active_coords = Some((latitude, longitude));
                                let _ = reply.send(Ok(()));
                            }
                            Err(e) => {
                                let _ = reply.send(Err(format!("Errore impostazione GPS: {e}")));
                            }
                        }
                    }
                    Some(SessionCommand::Clear { reply }) => {
                        active_coords = None;
                        match ls_client.clear().await {
                            Ok(()) => {
                                let _ = reply.send(Ok(()));
                            }
                            Err(e) => {
                                let _ = reply.send(Err(format!("Errore ripristino GPS: {e}")));
                            }
                        }
                    }
                    Some(SessionCommand::Disconnect { reply }) => {
                        if active_coords.is_some() {
                            let _ = ls_client.clear().await;
                        }
                        let _ = reply.send(());
                        break;
                    }
                    None => break,
                }
            }
            _ = keepalive.tick() => {
                if let Some((lat, lon)) = active_coords {
                    if ls_client.set(lat, lon).await.is_err() {
                        connected.store(false, Ordering::SeqCst);
                        break;
                    }
                }
            }
        }
    }

    drop(adapter);
    connected.store(false, Ordering::SeqCst);
}

async fn connect_rppairing_tunnel(
    host_ip: IpAddr,
    rp_port: u16,
    mut rpf: RpPairingFile,
) -> Result<(AdapterHandle, RsdHandshake, u16), String> {
    let candidate_ports: Vec<u16> = if rp_port != 0 {
        vec![rp_port]
    } else {
        vec![49152, 49153, 49154, 49155, 49156, 49157, 49158]
    };

    let mut chosen_stream = None;
    let mut chosen_port = 0u16;
    let mut last_err = String::new();

    for port in candidate_ports {
        let addr = SocketAddr::new(host_ip, port);
        match tokio::time::timeout(Duration::from_secs(3), tokio::net::TcpStream::connect(addr))
            .await
        {
            Ok(Ok(stream)) => {
                chosen_stream = Some(stream);
                chosen_port = port;
                break;
            }
            Ok(Err(e)) => {
                last_err = format!("{addr}: {e}");
            }
            Err(_) => {
                last_err = format!("{addr}: timeout");
            }
        }
    }

    let stream = chosen_stream.ok_or_else(|| {
        format!(
            "Impossibile raggiungere Remote Pairing su {host_ip} ({last_err}). Verifica LocalDevVPN attiva, Wi-Fi acceso e permesso Rete locale."
        )
    })?;

    let conn = RpPairingSocket::new(stream);
    let mut rpc = RemotePairingClient::new(conn, "PinShift");
    rpc.connect(&mut rpf, async || "000000".to_string())
        .await
        .map_err(|e| {
            format!(
                "Handshake Remote Pairing fallito (porta {chosen_port}): {e}. Rigenera il file Remote pairing in idevice_pair."
            )
        })?;

    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|e| format!("create_tcp_listener fallito: {e}"))?;

    let tunnel_addr = SocketAddr::new(host_ip, tunnel_port);
    let tunnel_stream = tokio::time::timeout(
        Duration::from_secs(8),
        tokio::net::TcpStream::connect(tunnel_addr),
    )
    .await
    .map_err(|_| format!("Timeout connessione tunnel TLS su {tunnel_addr}"))?
    .map_err(|e| format!("Connessione tunnel TLS su {tunnel_addr} fallita: {e}"))?;

    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|e| format!("TLS-PSK / CDTunnel handshake fallito: {e}"))?;

    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| format!("IP client tunnel non valido: {e}"))?;
    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| format!("IP server tunnel non valido: {e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let raw = tunnel.into_inner();
    let mut adapter = Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.min(8192).saturating_sub(60).max(536));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| format!("RSD connect (porta {rsd_port}): {e}"))?;
    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|e| format!("RSD handshake: {e}"))?;

    Ok((adapter, handshake, chosen_port))
}

async fn run_session(
    host_ip: IpAddr,
    rp_port: u16,
    pairing: PairingKind,
    mut rx: mpsc::Receiver<SessionCommand>,
    ready_tx: oneshot::Sender<Result<String, String>>,
    connected: Arc<AtomicBool>,
) {
    match pairing {
        PairingKind::RemotePairing(rpf) => {
            match connect_rppairing_tunnel(host_ip, rp_port, rpf).await {
                Ok((adapter, handshake, used_port)) => {
                    run_dvt_loop(
                        adapter,
                        handshake,
                        format!("Connesso via Remote Pairing (porta {used_port})"),
                        rx,
                        ready_tx,
                        connected,
                    )
                    .await;
                }
                Err(e) => {
                    connected.store(false, Ordering::SeqCst);
                    let _ = ready_tx.send(Err(e));
                }
            }
        }
        PairingKind::Lockdown(pairing_file) => {
            // Quick TCP probe to give exact OS error if port 62078 is unreachable/refused
            let lockdown_addr = SocketAddr::new(host_ip, 62078);
            if let Err(e) = tokio::time::timeout(
                Duration::from_secs(4),
                tokio::net::TcpStream::connect(lockdown_addr),
            )
            .await
            .map_err(|_| "timeout".to_string())
            .and_then(|r| r.map_err(|ioe| ioe.to_string()))
            {
                connected.store(false, Ordering::SeqCst);
                let _ = ready_tx.send(Err(format!(
                    "Porta Lockdown {lockdown_addr} non raggiungibile ({e}). Su iOS 26/27 genera invece un file 'Remote pairing' in idevice_pair!"
                )));
                return;
            }

            let provider = TcpProvider {
                addr: host_ip,
                scope_id: None,
                pairing_file,
                label: "PinShift".to_string(),
            };

            let modern_res = async {
                let proxy = CoreDeviceProxy::connect(&provider)
                    .await
                    .map_err(|e| format!("CoreDeviceProxy: {e}"))?;
                let rsd_port = proxy.tunnel_info().server_rsd_port;

                let adapter = proxy
                    .create_software_tunnel()
                    .map_err(|e| format!("Software tunnel: {e}"))?;
                let mut adapter = adapter.to_async_handle();

                let stream = adapter
                    .connect(rsd_port)
                    .await
                    .map_err(|e| format!("RSD connect (porta {rsd_port}): {e}"))?;
                let handshake = RsdHandshake::new(stream)
                    .await
                    .map_err(|e| format!("RSD handshake: {e}"))?;

                Ok::<_, String>((adapter, handshake))
            }
            .await;

            match modern_res {
                Ok((adapter, handshake)) => {
                    run_dvt_loop(
                        adapter,
                        handshake,
                        "Connesso via Lockdown / CoreDevice".to_string(),
                        rx,
                        ready_tx,
                        connected,
                    )
                    .await;
                }
                Err(modern_err) => match LocationSimulationService::connect(&provider).await {
                    Ok(mut legacy_client) => {
                        connected.store(true, Ordering::SeqCst);
                        let _ = ready_tx
                            .send(Ok("Connesso via servizio legacy (iOS <= 16)".to_string()));

                        while let Some(cmd) = rx.recv().await {
                            match cmd {
                                SessionCommand::Set {
                                    latitude,
                                    longitude,
                                    reply,
                                } => {
                                    let lat_s = format!("{latitude:.6}");
                                    let lon_s = format!("{longitude:.6}");
                                    match legacy_client.set(lat_s.as_str(), lon_s.as_str()).await {
                                        Ok(()) => {
                                            let _ = reply.send(Ok(()));
                                        }
                                        Err(e) => {
                                            let _ =
                                                reply.send(Err(format!("Errore GPS legacy: {e}")));
                                        }
                                    }
                                }
                                SessionCommand::Clear { reply } => {
                                    match legacy_client.clear().await {
                                        Ok(()) => {
                                            let _ = reply.send(Ok(()));
                                        }
                                        Err(e) => {
                                            let _ = reply
                                                .send(Err(format!("Errore ripristino GPS: {e}")));
                                        }
                                    }
                                }
                                SessionCommand::Disconnect { reply } => {
                                    let _ = legacy_client.clear().await;
                                    let _ = reply.send(());
                                    break;
                                }
                            }
                        }
                        connected.store(false, Ordering::SeqCst);
                    }
                    Err(legacy_err) => {
                        connected.store(false, Ordering::SeqCst);
                        let _ = ready_tx.send(Err(format!(
                            "Connessione Lockdown fallita (su iOS 26/27 usa un file Remote pairing!).\nCoreDevice: {modern_err}\nLegacy: {legacy_err}"
                        )));
                    }
                },
            }
        }
    }
}

fn disconnect_existing() {
    let existing = {
        let mut guard = session_lock().lock().unwrap_or_else(|e| e.into_inner());
        guard.take()
    };

    if let Some(session) = existing {
        let rt = runtime();
        let (reply_tx, reply_rx) = oneshot::channel();
        let _ = rt.block_on(async {
            let _ = session
                .tx
                .send(SessionCommand::Disconnect { reply: reply_tx })
                .await;
            let _ = tokio::time::timeout(Duration::from_secs(3), reply_rx).await;
        });
        session.connected.store(false, Ordering::SeqCst);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn locbridge_connect(
    host_ip: *const c_char,
    rp_port: u16,
    pairing_bytes: *const u8,
    pairing_len: usize,
) -> LocBridgeResult {
    if host_ip.is_null() {
        return LocBridgeResult::err(1, "Indirizzo IP mancante");
    }
    if pairing_bytes.is_null() || pairing_len == 0 {
        return LocBridgeResult::err(2, "Pairing file mancante o vuoto");
    }

    let host_str = unsafe {
        match CStr::from_ptr(host_ip).to_str() {
            Ok(s) => s.trim(),
            Err(_) => return LocBridgeResult::err(3, "Indirizzo IP non valido (UTF-8)"),
        }
    };

    let addr = match IpAddr::from_str(host_str) {
        Ok(ip) => ip,
        Err(e) => return LocBridgeResult::err(4, format!("IP '{host_str}' non valido: {e}")),
    };

    let raw_bytes = unsafe { std::slice::from_raw_parts(pairing_bytes, pairing_len) };

    // Auto-detect Remote Pairing (.rppairing) vs Lockdown (.plist)
    let pairing = if let Ok(rpf) = RpPairingFile::from_bytes(raw_bytes) {
        PairingKind::RemotePairing(rpf)
    } else if let Ok(pf) = PairingFile::from_bytes(raw_bytes) {
        PairingKind::Lockdown(pf)
    } else {
        return LocBridgeResult::err(
            5,
            "Pairing file non riconosciuto. Genera un file 'Remote pairing' (consigliato per iOS 26/27) oppure 'Lockdown' con idevice_pair.",
        );
    };

    disconnect_existing();

    let (tx, rx) = mpsc::channel::<SessionCommand>(16);
    let (ready_tx, ready_rx) = oneshot::channel::<Result<String, String>>();
    let connected = Arc::new(AtomicBool::new(false));
    let connected_task = Arc::clone(&connected);

    let rt = runtime();
    let spawn_res = std::thread::Builder::new()
        .name("pinshift-session".to_string())
        .stack_size(4 * 1024 * 1024)
        .spawn(move || {
            let local_rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = ready_tx.send(Err(format!("Errore avvio runtime: {e}")));
                    return;
                }
            };
            local_rt.block_on(run_session(
                addr,
                rp_port,
                pairing,
                rx,
                ready_tx,
                connected_task,
            ));
        });

    if let Err(e) = spawn_res {
        return LocBridgeResult::err(9, format!("Impossibile avviare il thread di sessione: {e}"));
    }

    let wait_res = rt.block_on(async {
        tokio::time::timeout(Duration::from_secs(20), ready_rx).await
    });

    match wait_res {
        Ok(Ok(Ok(info))) => {
            let mut guard = session_lock().lock().unwrap_or_else(|e| e.into_inner());
            *guard = Some(ActiveSession { tx, connected });
            LocBridgeResult::ok(info)
        }
        Ok(Ok(Err(err_msg))) => LocBridgeResult::err(6, err_msg),
        Ok(Err(_)) => {
            LocBridgeResult::err(7, "Sessione interrotta inaspettatamente durante la connessione")
        }
        Err(_) => LocBridgeResult::err(
            8,
            "Timeout connessione (20s). Verifica LocalDevVPN attiva, Wi-Fi acceso e permesso Rete locale.",
        ),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn locbridge_set_location(latitude: f64, longitude: f64) -> LocBridgeResult {
    if !latitude.is_finite() || !longitude.is_finite() {
        return LocBridgeResult::err(10, "Coordinate non valide");
    }
    if !(-90.0..=90.0).contains(&latitude) || !(-180.0..=180.0).contains(&longitude) {
        return LocBridgeResult::err(11, "Coordinate fuori intervallo (-90..90, -180..180)");
    }

    let tx = {
        let guard = session_lock().lock().unwrap_or_else(|e| e.into_inner());
        match guard.as_ref() {
            Some(s) if s.connected.load(Ordering::SeqCst) => s.tx.clone(),
            _ => return LocBridgeResult::err(12, "Non connesso al dispositivo"),
        }
    };

    let (reply_tx, reply_rx) = oneshot::channel();
    let res = runtime().block_on(async {
        tx.send(SessionCommand::Set {
            latitude,
            longitude,
            reply: reply_tx,
        })
        .await
        .map_err(|_| "Canale di sessione chiuso".to_string())?;

        tokio::time::timeout(Duration::from_secs(10), reply_rx)
            .await
            .map_err(|_| "Timeout durante l'invio delle coordinate".to_string())?
            .map_err(|_| "Sessione terminata prima della risposta".to_string())?
    });

    match res {
        Ok(()) => LocBridgeResult::ok(format!("Posizione impostata: {latitude:.5}, {longitude:.5}")),
        Err(e) => LocBridgeResult::err(13, e),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn locbridge_clear_location() -> LocBridgeResult {
    let tx = {
        let guard = session_lock().lock().unwrap_or_else(|e| e.into_inner());
        match guard.as_ref() {
            Some(s) if s.connected.load(Ordering::SeqCst) => s.tx.clone(),
            _ => return LocBridgeResult::err(20, "Non connesso al dispositivo"),
        }
    };

    let (reply_tx, reply_rx) = oneshot::channel();
    let res = runtime().block_on(async {
        tx.send(SessionCommand::Clear { reply: reply_tx })
            .await
            .map_err(|_| "Canale di sessione chiuso".to_string())?;

        tokio::time::timeout(Duration::from_secs(10), reply_rx)
            .await
            .map_err(|_| "Timeout durante il ripristino GPS".to_string())?
            .map_err(|_| "Sessione terminata prima della risposta".to_string())?
    });

    match res {
        Ok(()) => LocBridgeResult::ok("GPS reale ripristinato"),
        Err(e) => LocBridgeResult::err(21, e),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn locbridge_disconnect() -> LocBridgeResult {
    disconnect_existing();
    LocBridgeResult::ok("Disconnesso")
}

#[unsafe(no_mangle)]
pub extern "C" fn locbridge_is_connected() -> i32 {
    let guard = session_lock().lock().unwrap_or_else(|e| e.into_inner());
    match guard.as_ref() {
        Some(s) if s.connected.load(Ordering::SeqCst) => 1,
        _ => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn locbridge_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}
