// SPDX-License-Identifier: AGPL-3.0

use actix_web::{web, HttpRequest, HttpResponse, Error};
use futures_util::StreamExt;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use uuid::Uuid;

use app_core::auth;
use app_core::db::DbPools;
use app_core::models::chat::{CallStatus, ParticipantType};
use app_core::services::chat::ChatService;
use app_core::{CacheService};
use redis::AsyncCommands;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use tokio::sync::{watch, Notify};

use app_core::presence;
use app_core::notif_shared;
use std::collections::HashMap;
use crate::protocol::{ClientMessage, ServerEvent};
use crate::registry::{ConnectionHandle, ConnectionRegistry};

pub struct AppState {
    pub pools: DbPools,
    pub cache: CacheService,
    pub chat: ChatService,
    pub registry: ConnectionRegistry,
    pub node_id: String,
    pub ready: AtomicBool,
    pub draining: AtomicBool,
    pub active_sessions: AtomicUsize,
    drain_tx: watch::Sender<Option<u64>>,
}

impl AppState {
    pub fn new(pools: DbPools, cache: CacheService, chat: ChatService, registry: ConnectionRegistry) -> Self {
        let (drain_tx, _rx) = watch::channel(None);
        Self {
            pools,
            cache,
            chat,
            registry,
            node_id: Uuid::new_v4().simple().to_string(),
            ready: AtomicBool::new(false),
            draining: AtomicBool::new(false),
            active_sessions: AtomicUsize::new(0),
            drain_tx,
        }
    }

    pub fn begin_drain(&self, spread: Duration) {
        self.draining.store(true, Ordering::SeqCst);
        self.drain_tx.send_replace(Some(spread.as_millis().max(1) as u64));
    }

    fn subscribe_drain(&self) -> watch::Receiver<Option<u64>> {
        self.drain_tx.subscribe()
    }
}

struct SessionGuard(Arc<AppState>);

impl SessionGuard {
    fn new(state: &Arc<AppState>) -> Self {
        state.active_sessions.fetch_add(1, Ordering::SeqCst);
        Self(state.clone())
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        self.0.active_sessions.fetch_sub(1, Ordering::SeqCst);
    }
}

const OUTBOUND_QUEUE_CAP: usize = 512;

const WRITE_TIMEOUT: Duration = Duration::from_secs(10);

const CROSS_NODE_SEP: char = '\u{1f}';

async fn send_text(session: &mut actix_ws::Session, text: String) -> bool {
    matches!(tokio::time::timeout(WRITE_TIMEOUT, session.text(text)).await, Ok(Ok(())))
}

const PRESENCE_REFRESH_MIN_SECS: u64 = 10;

fn presence_refresh_due(last: &mut Option<tokio::time::Instant>) -> bool {
    match last {
        Some(t) if t.elapsed() < Duration::from_secs(PRESENCE_REFRESH_MIN_SECS) => false,
        _ => {
            *last = Some(tokio::time::Instant::now());
            true
        }
    }
}

fn presence_mode_watch() -> bool {
    static MODE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *MODE.get_or_init(|| std::env::var("PRESENCE_MODE").map(|v| v == "watch").unwrap_or(false))
}

const PRESENCE_WATCH_MAX: usize = 100;

async fn allowed_presence_watch_ids(
    state: &AppState,
    viewer_id: Uuid,
    mut requested: Vec<Uuid>,
) -> Option<Vec<String>> {
    requested.retain(|u| *u != viewer_id);
    requested.sort();
    requested.dedup();
    requested.truncate(PRESENCE_WATCH_MAX);

    let allowed: Vec<Uuid> = if requested.is_empty() {
        Vec::new()
    } else {
        match presence::active_conversation_partners(&state.pools, viewer_id).await {
            Ok(partners) => {
                let partners: std::collections::HashSet<Uuid> = partners.into_iter().collect();
                requested.into_iter().filter(|u| partners.contains(u)).collect()
            }
            Err(e) => {
                log::warn!("presence watch: partner lookup failed for {}: {}", viewer_id, e);
                return None;
            }
        }
    };

    Some(allowed.iter().map(|u| u.to_string()).collect())
}

async fn send_presence_for_targets(state: &AppState, viewer_id: Uuid, targets: &[Uuid]) {
    let Ok(map) = state.chat.presence_for_viewer(&state.pools, viewer_id, targets).await else { return };
    for target in targets {
        let Some(info) = map.get(target) else { continue };
        let Some(online) = info.online else { continue };
        let event = ServerEvent::PresenceChanged {
            user_id: *target,
            online,
            last_seen: info.last_seen,
        };
        if let Ok(payload) = serde_json::to_string(&event) {
            state.registry.deliver_local(viewer_id, &payload);
        }
    }
}

async fn forward_watched_presence(state: &AppState, viewer_id: Uuid, raw: &str) {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) else { return };
    let Some(target) = v.get("user_id").and_then(|x| x.as_str()).and_then(|s| Uuid::parse_str(s).ok()) else { return };
    send_presence_for_targets(state, viewer_id, &[target]).await;
}

const UNACKED_PUSH_DELAY: Duration =
    Duration::from_secs(notif_shared::DELIVERY_GUARD_DELAY_SECS as u64);

fn take_guard(
    pending: &mut HashMap<Uuid, (tokio::time::Instant, notif_shared::NotificationEvent)>,
    body: String,
) -> String {
    let Ok(mut v) = serde_json::from_str::<serde_json::Value>(&body) else { return body };
    let Some(obj) = v.as_object_mut() else { return body };
    let Some(guard) = obj.remove("_guard") else { return body };
    let message_id = obj
        .get("message")
        .and_then(|m| m.get("id"))
        .and_then(|i| i.as_str())
        .and_then(|s| Uuid::parse_str(s).ok());
    if let (Some(mid), Ok(ev)) = (message_id, serde_json::from_value::<notif_shared::NotificationEvent>(guard)) {
        pending.insert(mid, (tokio::time::Instant::now(), ev));
    }
    serde_json::to_string(&v).unwrap_or(body)
}

async fn release_unacked_push(
    pools: app_core::db::DbPools,
    cache: CacheService,
    recipient_id: Uuid,
    message_id: Uuid,
    event: notif_shared::NotificationEvent,
) {
    let still_unacked: bool = sqlx::query_scalar(
        r#"
        SELECT EXISTS (
            SELECT 1
            FROM messages m
            JOIN conversation_participants cp
              ON cp.conversation_id = m.conversation_id
             AND cp.participant_id = $2
             AND cp.left_at IS NULL
            LEFT JOIN message_receipts r
              ON r.message_id = m.id AND r.user_id = $2
            WHERE m.id = $1
              AND m.deleted_at IS NULL
              AND CASE
                  WHEN m.content_type = 'bit'
                      THEN (r.message_id IS NOT NULL AND r.delivered_at IS NULL AND r.opened_at IS NULL)
                  ELSE (m.seq IS NOT NULL AND cp.last_delivered_seq < m.seq)
              END
        )
        "#,
    )
    .bind(message_id)
    .bind(recipient_id)
    .fetch_one(pools.writer())
    .await
    .unwrap_or(true);
    if !still_unacked {
        return;
    }

    let mut conn = cache.client.clone();
    let lock: Result<Option<String>, redis::RedisError> = redis::cmd("SET")
        .arg(format!("guard:fired:{}:{}", message_id, recipient_id))
        .arg(1)
        .arg("NX")
        .arg("EX")
        .arg(60)
        .query_async(&mut conn)
        .await;
    if let Ok(None) = lock {
        return;
    }

    log::info!("ws: no delivered-ack for message {} -> releasing push to {}", message_id, recipient_id);
    if let Err(e) = notif_shared::publish_event(&cache, &event).await {
        log::error!("ws: failed to publish released push for message {}: {}", message_id, e);
    }
}

fn spread_jitter(session_id: Uuid, spread_ms: u64) -> Duration {
    Duration::from_millis((session_id.as_u128() as u64) % spread_ms.max(1))
}

fn max_session_secs() -> Option<u64> {
    std::env::var("WS_MAX_SESSION_SECS").ok().and_then(|v| v.parse::<u64>().ok()).filter(|v| *v > 0)
}

fn allow_query_token() -> bool {
    std::env::var("WS_ALLOW_QUERY_TOKEN").map(|v| v != "false" && v != "0").unwrap_or(true)
}

pub const OFFLINE_GRACE_PERIOD_SECS: u64 = 8;

const CONNECTION_COUNT_TTL_SECS: i64 = 90;

const IDLE_TIMEOUT_SECS: u64 = 3 * presence::HEARTBEAT_INTERVAL_SECS;

async fn incr_connection_count(cache: &CacheService, participant_id: Uuid) -> i64 {
    let mut conn = cache.client.clone();
    let key = format!("presence:conn_count:{}", participant_id);
    let res: Result<(i64,), redis::RedisError> = redis::pipe()
        .atomic()
        .cmd("INCR").arg(&key)
        .cmd("EXPIRE").arg(&key).arg(CONNECTION_COUNT_TTL_SECS).ignore()
        .query_async(&mut conn)
        .await;
    res.map(|(c,)| c).unwrap_or(1)
}

async fn decr_connection_count(cache: &CacheService, participant_id: Uuid) -> i64 {
    let mut conn = cache.client.clone();
    let key = format!("presence:conn_count:{}", participant_id);
    let count: i64 = conn.decr(&key, 1).await.unwrap_or(0);
    if count <= 0 {
        let _: Result<(), _> = conn.del(&key).await;
        0
    } else {
        count
    }
}

async fn current_connection_count(cache: &CacheService, participant_id: Uuid) -> i64 {
    let mut conn = cache.client.clone();
    conn.get(format!("presence:conn_count:{}", participant_id)).await.unwrap_or(0)
}

async fn enable_presence_for_session(state: &AppState, participant_id: Uuid) -> Option<presence::PresenceEntry> {
    let previous = presence::get_presence(&state.cache, participant_id).await;

    let _ = incr_connection_count(&state.cache, participant_id).await;
    let became_online = presence::heartbeat(&state.cache, participant_id).await.unwrap_or(false);
    if became_online {
        broadcast_presence(&state, participant_id, true).await;
    }

    send_presence_snapshot(state, participant_id).await;

    previous
}

async fn disable_presence_for_session(
    state: &AppState,
    participant_id: Uuid,
    previous: Option<presence::PresenceEntry>,
) {
    let remaining = decr_connection_count(&state.cache, participant_id).await;
    if remaining <= 0 {
        let still_online = previous.as_ref().map(|e| e.online).unwrap_or(false);
        let _ = presence::restore_presence(&state.cache, participant_id, previous).await;
        if !still_online {
            broadcast_presence(&state, participant_id, false).await;
        }
    }
}

pub async fn ws_handler(
    req: HttpRequest,
    stream: web::Payload,
    state: web::Data<Arc<AppState>>,
) -> Result<HttpResponse, Error> {
    if state.draining.load(Ordering::Relaxed) {
        return Ok(HttpResponse::ServiceUnavailable().finish());
    }

    let query_params = req
        .uri()
        .query()
        .and_then(|q| web::Query::<std::collections::HashMap<String, String>>::from_query(q).ok());

    let token = req
        .headers()
        .get("Authorization")
        .and_then(|h| h.to_str().ok())
        .map(|h| h.trim_start_matches("Bearer ").to_string())
        .or_else(|| {
            if allow_query_token() {
                query_params.as_ref().and_then(|q| q.get("token").cloned())
            } else {
                None
            }
        });

    let Some(token) = token else {
        return Ok(HttpResponse::Unauthorized().finish());
    };

    let presence_eligible = query_params
        .as_ref()
        .and_then(|q| q.get("presence").cloned())
        .map(|v| v != "false" && v != "0")
        .unwrap_or(true);

    let resume_cursor = query_params.as_ref().and_then(|q| q.get("resume").cloned());

    let claims = match auth::resolve_claims_from_token(&state.pools, &token).await {
        Ok(c) => c,
        Err(_) => return Ok(HttpResponse::Unauthorized().finish()),
    };

    let (participant_id, participant_type) = if claims.role == app_core::models::auth::Role::Service {
        match sqlx::query_scalar::<_, Uuid>("SELECT id FROM services WHERE owner_uid = $1")
            .bind(claims.user_id)
            .fetch_optional(state.pools.reader())
            .await
        {
            Ok(Some(service_id)) => (service_id, ParticipantType::Service),
            _ => return Ok(HttpResponse::NotFound().finish()),
        }
    } else {
        (claims.user_id, ParticipantType::User)
    };

    let (response, mut session, mut msg_stream) = actix_ws::handle(&req, stream)?;
    let session_id = Uuid::new_v4();
    let (tx, mut rx) = mpsc::channel::<String>(OUTBOUND_QUEUE_CAP);
    let slow_consumer = Arc::new(Notify::new());
    let session_guard = SessionGuard::new(state.get_ref());

    state.registry.register(
        participant_id,
        ConnectionHandle { session_id, sender: tx, slow_consumer: slow_consumer.clone() },
    );

    let state = state.clone();
    let mut drain_rx = state.subscribe_drain();
    actix_web::rt::spawn(async move {
        let _session_guard = session_guard;

        let _ = send_text(&mut session, serde_json::to_string(&ServerEvent::Connected { participant_id }).unwrap()).await;

        let cross_node_stream = state.cache.subscribe_user_channel(&participant_id.to_string()).await.ok();

        if let Some(frame) = state.chat.take_pending_call_signal(participant_id).await {
            let _ = send_text(&mut session, frame).await;
        }

        if presence_eligible {
            if let Some(cursor) = resume_cursor.as_deref() {
                for frame in state.chat.replay_inbox(&state.pools, participant_id, cursor).await {
                    if !send_text(&mut session, frame).await {
                        break;
                    }
                }
            }
        }

        let pre_promotion_presence = if presence_eligible {
            enable_presence_for_session(&state, participant_id).await
        } else {
            None
        };

        let connected_call_only = !presence_eligible;
        let mut presence_eligible = presence_eligible;
        let mut pre_promotion_presence = pre_promotion_presence;
        let mut heartbeat_interval = tokio::time::interval(Duration::from_secs(presence::HEARTBEAT_INTERVAL_SECS));
        let mut cross_node_stream = cross_node_stream;
        let mut idle_check_interval = tokio::time::interval(Duration::from_secs(5));
        let mut last_client_activity = tokio::time::Instant::now();
        let mut last_presence_refresh: Option<tokio::time::Instant> = None;
        let mut pending_acks: HashMap<Uuid, (tokio::time::Instant, notif_shared::NotificationEvent)> = HashMap::new();
        let mut ack_check_interval = tokio::time::interval(Duration::from_secs(1));
        let mut presence_watcher = state.cache.presence_watcher();
        let mut informed_disconnect = false;

        let mut close_at: Option<tokio::time::Instant> = max_session_secs().map(|secs| {
            tokio::time::Instant::now()
                + Duration::from_secs(secs)
                + spread_jitter(session_id, secs.saturating_mul(100))
        });

        if let Some(spread_ms) = *drain_rx.borrow_and_update() {
            let at = tokio::time::Instant::now() + spread_jitter(session_id, spread_ms);
            close_at = Some(close_at.map_or(at, |c| c.min(at)));
        }

        loop {
            let deadline = close_at;
            tokio::select! {
                Some(payload) = rx.recv() => {
                    if !send_text(&mut session, payload).await {
                        break;
                    }
                }

                _ = slow_consumer.notified() => {
                    log::warn!("ws session {} for participant {} is a slow consumer, closing", session_id, participant_id);
                    let _ = session.close(Some(actix_ws::CloseReason {
                        code: actix_ws::CloseCode::Again,
                        description: Some("slow consumer".into()),
                    })).await;
                    break;
                }

                res = drain_rx.changed() => {
                    if res.is_ok() {
                        if let Some(spread_ms) = *drain_rx.borrow_and_update() {
                            let at = tokio::time::Instant::now() + spread_jitter(session_id, spread_ms);
                            close_at = Some(close_at.map_or(at, |c| c.min(at)));
                        }
                    }
                }

                _ = async {
                    match deadline {
                        Some(t) => tokio::time::sleep_until(t).await,
                        None => std::future::pending::<()>().await,
                    }
                } => {
                    let _ = session.close(Some(actix_ws::CloseReason {
                        code: actix_ws::CloseCode::Restart,
                        description: Some("server restarting".into()),
                    })).await;
                    break;
                }

                Some(payload) = async {
                    match cross_node_stream.as_mut() {
                        Some(s) => s.next().await,
                        None => std::future::pending().await,
                    }
                } => {
                    let body = match payload.split_once(CROSS_NODE_SEP) {
                        Some((origin, _)) if origin == state.node_id => continue,
                        Some((_, body)) => body.to_string(),
                        None => payload,
                    };
                    let body = if body.contains("\"_guard\"") {
                        take_guard(&mut pending_acks, body)
                    } else {
                        body
                    };
                    if !send_text(&mut session, body).await {
                        break;
                    }
                }

                _ = heartbeat_interval.tick() => {
                    let mut conn = state.cache.client.clone();
                    let _: Result<(), _> = conn.expire(
                        format!("presence:conn_count:{}", participant_id),
                        CONNECTION_COUNT_TTL_SECS,
                    ).await;
                }

                msg = msg_stream.next() => {
                    match msg {
                        Some(Ok(actix_ws::Message::Text(text))) => {
                            last_client_activity = tokio::time::Instant::now();
                            if presence_eligible && presence_refresh_due(&mut last_presence_refresh) {
                                let _ = presence::heartbeat(&state.cache, participant_id).await;
                            }
                            if presence_eligible && text.contains("set_presence_watch") {
                                if let Ok(ClientMessage::SetPresenceWatch { user_ids }) = serde_json::from_str::<ClientMessage>(&text) {
                                    if let Some(ids) = allowed_presence_watch_ids(&state, participant_id, user_ids).await {
                                        let added: Vec<Uuid> = presence_watcher
                                            .set_watched(&ids)
                                            .await
                                            .into_iter()
                                            .filter_map(|s| Uuid::parse_str(&s).ok())
                                            .collect();
                                        if !added.is_empty() {
                                            let st = state.clone();
                                            actix_web::rt::spawn(async move {
                                                send_presence_for_targets(&st, participant_id, &added).await;
                                            });
                                        }
                                    }
                                    continue;
                                }
                            }
                            if !pending_acks.is_empty() {
                                if let Ok(ClientMessage::Delivered { message_id }) = serde_json::from_str::<ClientMessage>(&text) {
                                    pending_acks.remove(&message_id);
                                }
                            }
                            if handle_client_message(&state, participant_id, participant_type, &text, &mut presence_eligible, &mut pre_promotion_presence, connected_call_only).await {
                                informed_disconnect = true;
                                break;
                            }
                        }
                        Some(Ok(actix_ws::Message::Ping(bytes))) => {
                            last_client_activity = tokio::time::Instant::now();
                            if presence_eligible && presence_refresh_due(&mut last_presence_refresh) {
                                let _ = presence::heartbeat(&state.cache, participant_id).await;
                            }
                            let _ = tokio::time::timeout(WRITE_TIMEOUT, session.pong(&bytes)).await;
                        }
                        Some(Ok(actix_ws::Message::Pong(_))) => {
                            last_client_activity = tokio::time::Instant::now();
                            if presence_eligible && presence_refresh_due(&mut last_presence_refresh) {
                                let _ = presence::heartbeat(&state.cache, participant_id).await;
                            }
                        }
                        Some(Ok(actix_ws::Message::Close(reason))) => {
                            let is_deliberate_background_close = reason
                                .as_ref()
                                .map(|r| r.code == actix_ws::CloseCode::Normal
                                    && r.description.as_deref() == Some("background"))
                                .unwrap_or(false);
                            if is_deliberate_background_close {
                                informed_disconnect = true;
                            }
                            break;
                        }
                        None => break,
                        Some(Err(_)) => break,
                        _ => {}
                    }
                }

                Some(raw) = presence_watcher.recv() => {
                    let st = state.clone();
                    actix_web::rt::spawn(async move {
                        forward_watched_presence(&st, participant_id, &raw).await;
                    });
                }

                _ = ack_check_interval.tick() => {
                    if !pending_acks.is_empty() {
                        let due: Vec<Uuid> = pending_acks
                            .iter()
                            .filter(|(_, (t, _))| t.elapsed() >= UNACKED_PUSH_DELAY)
                            .map(|(id, _)| *id)
                            .collect();
                        for mid in due {
                            if let Some((_, ev)) = pending_acks.remove(&mid) {
                                actix_web::rt::spawn(release_unacked_push(
                                    state.pools.clone(), state.cache.clone(), participant_id, mid, ev,
                                ));
                            }
                        }
                    }
                }

                _ = idle_check_interval.tick() => {
                    if last_client_activity.elapsed() > Duration::from_secs(IDLE_TIMEOUT_SECS) {
                        log::info!(
                            "ws session {} for participant {} idle for over {}s, tearing down",
                            session_id, participant_id, IDLE_TIMEOUT_SECS
                        );
                        break;
                    }
                }
            }
        }

        if let Some(stream) = cross_node_stream.as_mut() {
            use futures_util::FutureExt;
            while let Some(Some(payload)) = stream.next().now_or_never() {
                let body = match payload.split_once(CROSS_NODE_SEP) {
                    Some((origin, _)) if origin == state.node_id => continue,
                    Some((_, body)) => body.to_string(),
                    None => payload,
                };
                if body.contains("\"_guard\"") {
                    let _ = take_guard(&mut pending_acks, body);
                }
            }
        }
        for (mid, (_, ev)) in pending_acks.drain() {
            actix_web::rt::spawn(release_unacked_push(
                state.pools.clone(), state.cache.clone(), participant_id, mid, ev,
            ));
        }

        state.registry.unregister(participant_id, session_id);

        if presence_eligible {
        let remaining = decr_connection_count(&state.cache, participant_id).await;

        if informed_disconnect {
            let _ = presence::mark_offline(&state.cache, participant_id).await;
            broadcast_presence(&state, participant_id, false).await;

            let _ = sqlx::query("UPDATE users SET last_seen_at = now() WHERE id = $1")
                .bind(participant_id)
                .execute(state.pools.writer())
                .await;
        } else if remaining <= 0 {
            let state = state.clone();
            actix_web::rt::spawn(async move {
                tokio::time::sleep(Duration::from_secs(OFFLINE_GRACE_PERIOD_SECS)).await;
                if current_connection_count(&state.cache, participant_id).await > 0 {
                    return;
                }

                let _ = presence::mark_offline(&state.cache, participant_id).await;
                broadcast_presence(&state, participant_id, false).await;

                let _ = sqlx::query("UPDATE users SET last_seen_at = now() WHERE id = $1")
                    .bind(participant_id)
                    .execute(state.pools.writer())
                    .await;
            });
        }
        }
    });

    Ok(response)
}

async fn broadcast_presence(state: &AppState, user_id: Uuid, online: bool) {
    if presence_mode_watch() {
        let last_seen = presence::get_presence(&state.cache, user_id).await.map(|e| e.last_seen);
        let payload = serde_json::json!({ "user_id": user_id, "online": online, "last_seen": last_seen }).to_string();
        if let Err(e) = state.cache.publish_presence_event(&user_id.to_string(), &payload).await {
            log::warn!("presence: publish for {} failed: {}", user_id, e);
        }
        return;
    }
    let Ok(partners) = presence::active_conversation_partners(&state.pools, user_id).await else { return };
    if partners.is_empty() {
        return;
    }

    state.chat.invalidate_conversation_list_caches(&partners).await;

    let Ok(presence_by_partner) = state.chat.presence_for_broadcast(&state.pools, user_id, &partners).await else { return };

    debug_assert!(
        presence_by_partner.values().filter_map(|p| p.online).all(|seen| seen == online),
        "broadcast_presence: Valkey entry disagreed with the online flag just written"
    );

    for partner_id in partners {
        let Some(presence) = presence_by_partner.get(&partner_id) else { continue };
        let Some(visible_online) = presence.online else { continue };
        let event = ServerEvent::PresenceChanged {
            user_id,
            online: visible_online,
            last_seen: presence.last_seen,
        };
        let Ok(payload) = serde_json::to_string(&event) else { continue };
        route_to_participant(state, partner_id, &payload).await;
    }
}

async fn send_presence_snapshot(state: &AppState, participant_id: Uuid) {
    if presence_mode_watch() {
        return;
    }
    let Ok(partners) = presence::active_conversation_partners(&state.pools, participant_id).await else {
        return;
    };
    if partners.is_empty() {
        return;
    }
    let Ok(presence_by_partner) = state.chat.presence_for_broadcast(&state.pools, participant_id, &partners).await else {
        return;
    };
    for partner_id in &partners {
        let Some(presence) = presence_by_partner.get(partner_id) else { continue };
        let Some(online) = presence.online else { continue };
        let event = ServerEvent::PresenceChanged { user_id: *partner_id, online, last_seen: presence.last_seen };
        if let Ok(frame) = serde_json::to_string(&event) {
            state.registry.deliver_local(participant_id, &frame);
        }
    }
}

async fn route_to_participant(state: &AppState, participant_id: Uuid, payload: &str) -> bool {
    let local = state.registry.deliver_local(participant_id, payload);
    let tagged = format!("{}{}{}", state.node_id, CROSS_NODE_SEP, payload);
    let subscribers = match state.cache.publish_user_event(&participant_id.to_string(), &tagged).await {
        Ok(n) => n as i64,
        Err(_) => 0,
    };
    let remote = (subscribers - local as i64).max(0);
    local > 0 || remote > 0
}

async fn handle_client_message(
    state: &AppState,
    sender_id: Uuid,
    sender_type: ParticipantType,
    raw: &str,
    presence_eligible: &mut bool,
    pre_promotion_presence: &mut Option<presence::PresenceEntry>,
    connected_call_only: bool,
) -> bool {
    let Ok(msg) = serde_json::from_str::<ClientMessage>(raw) else {
        return false;
    };

    match msg {
        ClientMessage::AppDidBecomeActive => {
            if !*presence_eligible {
                *presence_eligible = true;
                *pre_promotion_presence = enable_presence_for_session(state, sender_id).await;
            }
        }

        ClientMessage::AppDidBecomeBackgroundOnly => {
            if connected_call_only && *presence_eligible {
                *presence_eligible = false;
                disable_presence_for_session(state, sender_id, pre_promotion_presence.take()).await;
            } else if *presence_eligible {
                log::warn!(
                    "app_did_become_background_only: ignoring for {} — session was presence-eligible from connect, not promoted",
                    sender_id
                );
            }
        }

        ClientMessage::Disconnecting => {
            return true;
        }

        ClientMessage::SendMessage { conversation_id, request, client_temp_id } => {
            let temp_id_for_err = client_temp_id.clone();
            if let Err(e) = state.chat.send_message(&state.pools, conversation_id, sender_id, sender_type, request, client_temp_id).await {
                log::warn!("ws send_message rejected for {}: {}", sender_id, e);
                let (status, code, message) = e.wire_error();
                let event = ServerEvent::SendFailed { conversation_id, client_temp_id: temp_id_for_err, status, code, message };
                if let Ok(payload) = serde_json::to_string(&event) {
                    route_to_participant(state, sender_id, &payload).await;
                }
            }
        }

        ClientMessage::Typing { conversation_id } => {
            if let Ok(other_ids) = state.chat.typing_recipient_ids(&state.pools, conversation_id, sender_id).await {
                let event = ServerEvent::Typing { conversation_id, user_id: sender_id };
                if let Ok(payload) = serde_json::to_string(&event) {
                    for other_id in other_ids {
                        route_to_participant(state, other_id, &payload).await;
                    }
                }
            }
        }

        ClientMessage::LocationUpdate { conversation_id, lat, lng } => {
            if app_core::services::e2ee::conversation_is_e2ee(&state.pools, conversation_id).await.unwrap_or(false) {
                let event = ServerEvent::SendFailed {
                    conversation_id, client_temp_id: None, status: 428,
                    code: "e2ee/encryption-required".into(),
                    message: "Live location in an encrypted chat must be encrypted".into(),
                };
                if let Ok(payload) = serde_json::to_string(&event) {
                    route_to_participant(state, sender_id, &payload).await;
                }
            } else if let Ok(recipients) = state.chat.live_share_recipients(&state.pools, conversation_id, sender_id).await {
                if !recipients.is_empty() {
                    let event = ServerEvent::LocationUpdate { conversation_id, user_id: sender_id, lat, lng };
                    if let Ok(payload) = serde_json::to_string(&event) {
                        for recipient_id in recipients {
                            route_to_participant(state, recipient_id, &payload).await;
                        }
                    }
                }
            }
        }

        ClientMessage::LocationUpdateE2ee { conversation_id, e2ee } => {
            match app_core::services::e2ee::validate_ephemeral(&state.pools, conversation_id, sender_id, &e2ee).await {
                Ok(per_user) => {
                    for (recipient_id, out) in per_user {
                        let event = ServerEvent::LocationUpdateE2ee { conversation_id, user_id: sender_id, e2ee: out };
                        if let Ok(payload) = serde_json::to_string(&event) {
                            route_to_participant(state, recipient_id, &payload).await;
                        }
                    }
                }
                Err(e) => {
                    let (status, code, message) = e.wire();
                    let event = ServerEvent::SendFailed { conversation_id, client_temp_id: None, status, code: code.to_string(), message };
                    if let Ok(payload) = serde_json::to_string(&event) {
                        route_to_participant(state, sender_id, &payload).await;
                    }
                }
            }
        }

        ClientMessage::StopLocationShare { conversation_id, message_id } => {
            match state.chat.stop_location_share(&state.pools, conversation_id, message_id, sender_id).await {
                Ok(()) => {
                    if let Ok(recipients) = state.chat.active_participant_ids(&state.pools, conversation_id, sender_id).await {
                        let event = ServerEvent::LocationShareStopped { conversation_id, message_id, user_id: sender_id };
                        if let Ok(payload) = serde_json::to_string(&event) {
                            for recipient_id in recipients {
                                route_to_participant(state, recipient_id, &payload).await;
                            }
                        }
                    }
                }
                Err(e) => {
                    log::warn!("stop_location_share rejected for message {} (sender {}): {}", message_id, sender_id, e);
                }
            }
        }

        ClientMessage::Delivered { message_id } => {
            let _ = state.chat.mark_delivered(&state.pools, message_id, sender_id).await;
        }

        ClientMessage::CallSignal { call_id, payload } => {
            let Ok(call) = state.chat.get_call(&state.pools, call_id).await else {
                log::warn!("call_signal: unknown call {} from {}", call_id, sender_id);
                return false;
            };
            let other_id = if call.caller_id == sender_id {
                call.callee_id
            } else if call.callee_id == sender_id {
                call.caller_id
            } else {
                log::warn!("call_signal: {} is not a participant in call {}", sender_id, call_id);
                return false;
            };
            let signal_type = payload.get("type").and_then(|t| t.as_str()).map(str::to_owned);

            let mut payload = payload;
            if app_core::services::e2ee::conversation_is_e2ee(&state.pools, call.conversation_id).await.unwrap_or(false)
                && signal_type.as_deref() != Some("end")
            {
                let parsed = payload
                    .get("e2ee")
                    .cloned()
                    .and_then(|v| serde_json::from_value::<app_core::models::e2ee::EphemeralE2ee>(v).ok());
                let fail = |status: u16, code: &str, message: String| ServerEvent::SendFailed {
                    conversation_id: call.conversation_id, client_temp_id: None, status, code: code.to_string(), message,
                };
                let Some(e2ee) = parsed else {
                    let ev = fail(428, "e2ee/encryption-required", "Call signalling in an encrypted chat must be encrypted".into());
                    if let Ok(f) = serde_json::to_string(&ev) { route_to_participant(state, sender_id, &f).await; }
                    return false;
                };
                match app_core::services::e2ee::validate_ephemeral(&state.pools, call.conversation_id, sender_id, &e2ee).await {
                    Ok(mut per_user) => {
                        let Some(out) = per_user.remove(&other_id) else { return false };
                        payload = serde_json::json!({
                            "type": signal_type.clone().unwrap_or_default(),
                            "e2ee": out,
                        });
                    }
                    Err(e) => {
                        let (status, code, message) = e.wire();
                        let ev = fail(status, code, message);
                        if let Ok(f) = serde_json::to_string(&ev) { route_to_participant(state, sender_id, &f).await; }
                        return false;
                    }
                }
            }
            let event = ServerEvent::CallSignal { call_id, payload };
            if let Ok(frame) = serde_json::to_string(&event) {
                let delivered = route_to_participant(state, other_id, &frame).await;

                let sig = signal_type.as_deref();
                let critical = matches!(sig, Some("offer") | Some("answer") | Some("end"));
                let ringing_offer = sig == Some("offer") && call.status == CallStatus::Ringing;
                if critical && (!delivered || ringing_offer) {
                    if !delivered {
                        log::warn!(
                            "call_signal: {} for call {} reached zero live sockets for {}, stashing for connect-time replay",
                            sig.unwrap_or("?"), call_id, other_id
                        );
                    }
                    state.chat.stash_pending_call_signal(call_id, other_id, &frame).await;
                }
            }

            if signal_type.as_deref() == Some("end") && matches!(call.status, CallStatus::Ringing | CallStatus::Ongoing) {
                if let Err(e) = state.chat.update_call_status_and_notify(&state.pools, call_id, CallStatus::Ended, sender_id).await {
                    log::warn!(
                        "call_signal end-hint: failed to mark call {} ended on behalf of {}: {:?}",
                        call_id, sender_id, e
                    );
                }
            }
        }

        ClientMessage::SetPresenceWatch { .. } => {}

        ClientMessage::Ping => {
            let event = ServerEvent::Pong;
            if let Ok(frame) = serde_json::to_string(&event) {
                state.registry.deliver_local(sender_id, &frame);
            }
        }

        ClientMessage::CallRingingAck { call_id } => {
            let Ok(call) = state.chat.get_call(&state.pools, call_id).await else {
                log::warn!("call_ringing_ack: unknown call {} from {}", call_id, sender_id);
                return false;
            };

            if call.callee_id != sender_id {
                log::warn!("call_ringing_ack: {} is not the callee on call {}", sender_id, call_id);
                return false;
            }

            if call.status != CallStatus::Ringing {
                return false;
            }

            let event = ServerEvent::CallRinging { call_id, conversation_id: call.conversation_id };
            if let Ok(frame) = serde_json::to_string(&event) {
                if !route_to_participant(state, call.caller_id, &frame).await {
                    log::warn!(
                        "call_ringing_ack: CallRinging for call {} reached zero live sockets for caller {}, stashing for connect-time replay",
                        call_id, call.caller_id
                    );
                    state.chat.stash_pending_call_signal(call_id, call.caller_id, &frame).await;
                }
            }
        }
    }

    false
}
