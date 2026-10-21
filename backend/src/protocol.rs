// SPDX-License-Identifier: AGPL-3.0

use serde::{Deserialize, Serialize};
use app_core::models::chat::{CallType, CallStatus, SendMessageRequest};
use app_core::models::e2ee::{EphemeralE2ee, EphemeralE2eeOut};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    SendMessage {
        conversation_id: Uuid,
        request: SendMessageRequest,
        client_temp_id: Option<String>,
    },
    Typing {
        conversation_id: Uuid,
    },
    SetPresenceWatch {
        user_ids: Vec<Uuid>,
    },
    Delivered {
        message_id: Uuid,
    },
    CallSignal {
        call_id: Uuid,
        payload: serde_json::Value,
    },
    LocationUpdate {
        conversation_id: Uuid,
        lat: f64,
        lng: f64,
    },

    LocationUpdateE2ee {
        conversation_id: Uuid,
        e2ee: EphemeralE2ee,
    },

    StopLocationShare {
        conversation_id: Uuid,
        message_id: Uuid,
    },

    Disconnecting,

    Ping,

    CallRingingAck {
        call_id: Uuid,
    },

    AppDidBecomeActive,

    AppDidBecomeBackgroundOnly,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerEvent {
    NewMessage {
        conversation_id: Uuid,
        message: app_core::models::chat::Message,
    },
    MessageAck {
        client_temp_id: String,
        message: app_core::models::chat::Message,
    },
    Delivered {
        message_id: Uuid,
        user_id: Uuid,
    },
    Opened {
        conversation_id: Uuid,
        up_to_message_id: Uuid,
        user_id: Uuid,
        read_at: chrono::DateTime<chrono::Utc>,
        opens_bit: bool,
    },
    ReactionUpdated {
        conversation_id: Uuid,
        message_id: Uuid,
        reactions: Vec<app_core::models::chat::MessageReaction>,
    },
    MessageDeleted {
        conversation_id: Uuid,
        message_id: Uuid,
        deleted_at: chrono::DateTime<chrono::Utc>,
    },
    MessageEdited {
        conversation_id: Uuid,
        message_id: Uuid,
        text_content: String,
        edited_at: chrono::DateTime<chrono::Utc>,
    },
    Typing {
        conversation_id: Uuid,
        user_id: Uuid,
    },
    LocationUpdate {
        conversation_id: Uuid,
        user_id: Uuid,
        lat: f64,
        lng: f64,
    },
    LocationUpdateE2ee {
        conversation_id: Uuid,
        user_id: Uuid,
        e2ee: EphemeralE2eeOut,
    },
    LocationShareStopped {
        conversation_id: Uuid,
        message_id: Uuid,
        user_id: Uuid,
    },
    PresenceChanged {
        user_id: Uuid,
        online: bool,
        last_seen: Option<chrono::DateTime<chrono::Utc>>,
    },
    IncomingCall {
        call_id: Uuid,
        conversation_id: Uuid,
        caller_id: Uuid,
        caller_name: String,
        call_type: CallType,
    },
    CallSignal {
        call_id: Uuid,
        payload: serde_json::Value,
    },
    CallStatusChanged {
        call_id: Uuid,
        conversation_id: Uuid,
        status: CallStatus,
    },
    Connected {
        participant_id: Uuid,
    },
    CallRinging {
        call_id: Uuid,
        conversation_id: Uuid,
    },
    Pong,
    SendFailed {
        conversation_id: Uuid,
        client_temp_id: Option<String>,
        status: u16,
        code: String,
        message: String,
    },
    Error {
        message: String,
    },
}
