// SPDX-License-Identifier: AGPL-3.0

use actix_web::{web, HttpResponse, Responder, Error};
use crate::auth::AuthClaims;
use crate::auth::push_ack::PushAckClaims;
use crate::services::CacheService;
use app_core::services::chat::{ChatService, ChatError, ConversationKind, ConversationView, decode_conversation_cursor};
use app_core::services::e2ee::{self, E2eeError};
use crate::models::e2ee::*;
use crate::services::services::ServiceAccountService;
use crate::db::DbPools;
use crate::models::*;
use crate::models::chat::*;
use uuid::Uuid;

pub fn configure(cfg: &mut web::ServiceConfig) {
    cfg.service(
        web::scope("/conversations")
            .route("", web::get().to(list_conversations))
            .route("/unread-summary", web::get().to(unread_summary))
            .route("/direct", web::post().to(start_direct_conversation))
            .route("/group/suggestions", web::get().to(get_group_suggestions))
            .route("/group/invite/{token}", web::get().to(get_group_invite_preview))
            .route("/group/join", web::post().to(join_group_via_invite))
            .route("/{id}", web::get().to(get_conversation))
            .route("/{id}/messages", web::get().to(get_messages))
            .route("/{id}/messages", web::post().to(send_message))
            .route("/{id}/messages/{message_id}/delivered", web::post().to(mark_delivered_route))
            .route("/{id}/messages/{message_id}/push-ack-delivered", web::post().to(mark_delivered_push_ack_route))
            .route("/{id}/messages/{message_id}/e2ee-push", web::get().to(e2ee_push_ciphertext_route))
            .route("/{id}/read", web::post().to(mark_read))
            .route("/{id}/read-receipts", web::get().to(get_read_receipts))
            .route("/{id}/accept", web::post().to(accept_request))
            .route("/{id}/decline", web::post().to(decline_request))
            .route("/{id}", web::delete().to(hide_conversation))
            .route("/{id}/history", web::delete().to(delete_conversation_history))
            .route("/{id}/settings", web::patch().to(update_settings))
            .route("/{id}/presence", web::get().to(get_presence))
            .route("/{id}/block", web::post().to(chat_block))
            .route("/{id}/unblock", web::post().to(chat_unblock))
            .route("/{id}/calls", web::post().to(create_call))
            .route("/{id}/e2ee/enable", web::post().to(e2ee_enable_conversation))
            .route("/{id}/e2ee/devices", web::get().to(e2ee_conversation_devices))
            .route("/group", web::post().to(create_group))
            .route("/{id}/group", web::get().to(get_group_details))
            .route("/{id}/group", web::patch().to(update_group))
            .route("/{id}/group/members", web::post().to(add_group_members))
            .route("/{id}/group/members/{user_id}", web::delete().to(remove_group_member))
            .route("/{id}/group/leave", web::post().to(leave_group))
            .route("/{id}/group/creators", web::post().to(promote_group_creator))
            .route("/{id}/group/invite-link", web::patch().to(set_group_invite_link))
            .route("/{id}/group", web::delete().to(delete_group)),
    )
    .service(
        web::scope("/e2ee")
            .route("/prekey-bundles", web::post().to(e2ee_prekey_bundles))
            .route("/devices", web::put().to(e2ee_register_device))
            .route("/devices", web::get().to(e2ee_list_devices))
            .route("/devices/{device_id}", web::delete().to(e2ee_revoke_device))
            .route("/devices/{device_id}/prekeys", web::get().to(e2ee_prekey_counts))
            .route("/devices/{device_id}/prekeys", web::post().to(e2ee_upload_prekeys))
            .route("/devices/{device_id}/signed-prekey", web::put().to(e2ee_rotate_signed_prekey)),
    )
    .service(
        web::scope("/calls")
            .route("/{id}", web::patch().to(update_call_status))
            .route("/{id}/turn-credentials", web::get().to(get_call_turn_credentials))
            .route("/{id}/pending-signal", web::get().to(get_pending_call_signal))
            .route("/{id}/heartbeat", web::post().to(call_heartbeat)),
    )
    .service(
        web::scope("/messages")
            .route("/{message_id}/reactions", web::post().to(add_reaction))
            .route("/{message_id}/reactions/{emoji}", web::delete().to(remove_reaction))
            .route("/{message_id}/receipts", web::get().to(get_message_receipts_route))
            .route("/{message_id}", web::delete().to(delete_message))
            .route("/{message_id}", web::patch().to(edit_message)),
    );
}

async fn resolve_caller_identity(
    pools: &DbPools,
    cache: &web::Data<CacheService>,
    claims: &AuthClaims,
) -> Result<(Uuid, ParticipantType), HttpResponse> {
    if claims.is_service() {
        let svc = ServiceAccountService::new(cache.get_ref().clone());
        match svc.service_id_for_owner(pools, claims.user_id).await {
            Ok(Some(service_id)) => Ok((service_id, ParticipantType::Service)),
            _ => Err(HttpResponse::NotFound().json(
                ApiResponse::<String>::error("Service not found for this account".to_string(), "chat/service-not-found".to_string())
            )),
        }
    } else {
        Ok((claims.user_id, ParticipantType::User))
    }
}

fn map_chat_error(e: ChatError) -> HttpResponse {
    match e {
        ChatError::NotParticipant => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error("Not a participant in this conversation".to_string(), "chat/not-participant".to_string())
        ),
        ChatError::RequestNotAccepted => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error("Accept the conversation request before replying".to_string(), "chat/request-not-accepted".to_string())
        ),
        ChatError::Blocked => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error("Messaging is not available between these accounts".to_string(), "chat/blocked".to_string())
        ),
        ChatError::NotFound => HttpResponse::NotFound().json(
            ApiResponse::<String>::error("Not found".to_string(), "chat/not-found".to_string())
        ),
        ChatError::NotGroupCreator => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error("Only a group creator can do this".to_string(), "chat/not-group-creator".to_string())
        ),
        ChatError::GroupDeleted => HttpResponse::Gone().json(
            ApiResponse::<String>::error("This group has been deleted".to_string(), "chat/group-deleted".to_string())
        ),
        ChatError::LeftConversation => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error("You have left this conversation".to_string(), "chat/left-conversation".to_string())
        ),
        ChatError::TooManyParticipants => HttpResponse::BadRequest().json(
            ApiResponse::<String>::error("Too many participants".to_string(), "chat/too-many-participants".to_string())
        ),
        ChatError::InvalidGroupRequest => HttpResponse::BadRequest().json(
            ApiResponse::<String>::error("Invalid group request".to_string(), "chat/invalid-group-request".to_string())
        ),
        ChatError::FollowRequiredToMessage(_) => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error(e.to_string(), "chat/follow-required-to-message".to_string())
        ),
        ChatError::FollowRequiredToInvite(_) => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error(e.to_string(), "chat/follow-required-to-invite".to_string())
        ),
        ChatError::BlockedInvitees(_) => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error(e.to_string(), "chat/blocked-invitees".to_string())
        ),
        ChatError::CallEnded => HttpResponse::Gone().json(
            ApiResponse::<String>::error("This call has already ended".to_string(), "chat/call-ended".to_string())
        ),
        ChatError::DeleteWindowExpired => HttpResponse::Gone().json(
            ApiResponse::<String>::error("Too much time has passed to delete this message".to_string(), "chat/delete-window-expired".to_string())
        ),
        ChatError::EmptyMessage => HttpResponse::BadRequest().json(
            ApiResponse::<String>::error("Message cannot be empty".to_string(), "chat/empty-message".to_string())
        ),
        ChatError::EditWindowExpired => HttpResponse::Gone().json(
            ApiResponse::<String>::error("Too much time has passed to edit this message".to_string(), "chat/edit-window-expired".to_string())
        ),
        ChatError::E2ee(err) => map_e2ee_error(err),
        ChatError::Db(err) => {
            eprintln!("ERROR: chat db error: {}", err);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Something went wrong".to_string(), "chat/internal-error".to_string())
            )
        }
    }
}

fn map_e2ee_error(e: E2eeError) -> HttpResponse {
    if let E2eeError::Db(err) = &e {
        eprintln!("ERROR: e2ee db error: {}", err);
    }
    let (status, code, message) = e.wire();
    let status = actix_web::http::StatusCode::from_u16(status).unwrap_or(actix_web::http::StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status).json(ApiResponse::<String>::error(message, code.to_string()))
}

async fn list_conversations(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    query: web::Query<std::collections::HashMap<String, String>>,
) -> impl Responder {
    let (caller_id, _caller_type) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let view = match query.get("view").map(|s| s.as_str()).unwrap_or("messages") {
        "invitations" => ConversationView::Invitations,
        "archives" => ConversationView::Archives,
        _ => ConversationView::Messages,
    };
    let kind = ConversationKind::from_query(query.get("kind").map(|s| s.as_str()));
    let page_size = query.get("page_size").and_then(|p| p.parse().ok()).unwrap_or(20);
    let exclude_left_groups = query.get("exclude_left_groups").and_then(|p| p.parse().ok()).unwrap_or(false);

    let chat = ChatService::new(cache.get_ref().clone());

    if let Some(cursor_param) = query.get("cursor") {
        let cursor = decode_conversation_cursor(cursor_param);
        return match chat.list_conversations_cursor(&pools, caller_id, view, cursor, page_size, exclude_left_groups, kind).await {
            Ok((list, next_cursor)) => {
                let mut resp = HttpResponse::Ok();
                if let Some(next) = next_cursor {
                    resp.insert_header(("X-Next-Cursor", next));
                }
                resp.json(ApiResponse::success(list))
            }
            Err(e) => {
                eprintln!("ERROR: list_conversations (cursor) failed for {}: {}", caller_id, e);
                HttpResponse::InternalServerError().json(
                    ApiResponse::<String>::error("Failed to fetch conversations".to_string(), "chat/list-failed".to_string())
                )
            }
        };
    }

    let page = query.get("page").and_then(|p| p.parse().ok()).unwrap_or(0);
    match chat.list_conversations(&pools, caller_id, view, page, page_size, exclude_left_groups, kind).await {
        Ok(list) => HttpResponse::Ok().json(ApiResponse::success(list)),
        Err(e) => {
            eprintln!("ERROR: list_conversations failed for {}: {}", caller_id, e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to fetch conversations".to_string(), "chat/list-failed".to_string())
            )
        }
    }
}

async fn unread_summary(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.unread_summary(&pools, caller_id).await {
        Ok((messages_unread, requests_unread)) => HttpResponse::Ok()
            .insert_header(("Cache-Control", "no-store"))
            .json(ApiResponse::success(serde_json::json!({
                "messages_unread": messages_unread,
                "requests_unread": requests_unread,
            }))),
        Err(e) => {
            eprintln!("ERROR: unread_summary failed for {}: {}", caller_id, e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to fetch unread summary".to_string(), "chat/unread-summary-failed".to_string())
            )
        }
    }
}

async fn start_direct_conversation(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    body: web::Json<StartDirectConversationRequest>,
) -> impl Responder {
    let (caller_id, caller_type) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_or_create_direct(&pools, caller_id, caller_type, body.other_id, body.other_type).await {
        Ok((conversation, other_status, my_status)) => {
            let mut body = serde_json::to_value(DirectConversationResponse { conversation, other_status })
                .unwrap_or(serde_json::Value::Null);
            if let (Some(obj), Ok(v)) = (body.as_object_mut(), serde_json::to_value(my_status)) {
                obj.insert("my_status".to_string(), v);
            }
            HttpResponse::Ok().json(ApiResponse::success(body))
        }
        Err(e) => map_chat_error(e),
    }
}

async fn get_conversation(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_conversation_details(&pools, path.into_inner(), caller_id).await {
        Ok(summary) => HttpResponse::Ok().json(ApiResponse::success(summary)),
        Err(e) => map_chat_error(e),
    }
}

async fn hide_conversation(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.decline_or_hide(&pools, path.into_inner(), caller_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Conversation removed".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn delete_conversation_history(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.delete_conversation_history(&pools, path.into_inner(), caller_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Chat history deleted".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn get_messages(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    query: web::Query<std::collections::HashMap<String, String>>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let before = query.get("before").and_then(|s| Uuid::parse_str(s).ok());
    let limit = query.get("limit").and_then(|p| p.parse().ok()).unwrap_or(50);

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_messages(&pools, path.into_inner(), caller_id, before, limit).await {
        Ok(messages) => HttpResponse::Ok().json(ApiResponse::success(messages)),
        Err(e) => map_chat_error(e),
    }
}

async fn send_message(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<SendMessageRequest>,
) -> impl Responder {
    let (caller_id, caller_type) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.send_message(&pools, path.into_inner(), caller_id, caller_type, body.into_inner(), None).await {
        Ok(message) => HttpResponse::Created().json(ApiResponse::success(message)),
        Err(e) => map_chat_error(e),
    }
}

async fn mark_read(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<MarkReadRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.mark_read(&pools, path.into_inner(), caller_id, body.up_to_message_id, body.opens_bit).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Marked as read".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn get_read_receipts(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_read_receipts(&pools, path.into_inner(), caller_id).await {
        Ok(receipts) => HttpResponse::Ok().json(ApiResponse::success(receipts)),
        Err(e) => map_chat_error(e),
    }
}

async fn get_message_receipts_route(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_message_receipts(&pools, path.into_inner(), caller_id).await {
        Ok(receipts) => HttpResponse::Ok().json(ApiResponse::success(receipts)),
        Err(e) => map_chat_error(e),
    }
}

async fn add_reaction(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<AddReactionRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.add_reaction(&pools, path.into_inner(), caller_id, body.into_inner().emoji).await {
        Ok(reaction) => HttpResponse::Created().json(ApiResponse::success(reaction)),
        Err(e) => map_chat_error(e),
    }
}

async fn remove_reaction(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<(Uuid, String)>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let (message_id, emoji) = path.into_inner();
    let chat = ChatService::new(cache.get_ref().clone());
    match chat.remove_reaction(&pools, message_id, caller_id, emoji).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Reaction removed".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn delete_message(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.delete_message(&pools, path.into_inner(), caller_id).await {
        Ok(message) => HttpResponse::Ok().json(ApiResponse::success(message)),
        Err(e) => map_chat_error(e),
    }
}

async fn edit_message(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<EditMessageRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    let body = body.into_inner();
    match chat.edit_message(&pools, path.into_inner(), caller_id, body.text, body.e2ee).await {
        Ok(message) => HttpResponse::Ok().json(ApiResponse::success(message)),
        Err(e) => map_chat_error(e),
    }
}

async fn accept_request(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.accept_request(&pools, path.into_inner(), caller_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Request accepted".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn decline_request(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    hide_conversation(pools, cache, claims, path).await
}

async fn update_settings(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<UpdateConversationSettingsRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.update_settings(&pools, path.into_inner(), caller_id, body.into_inner()).await {
        Ok(participant) => HttpResponse::Ok().json(ApiResponse::success(participant)),
        Err(e) => map_chat_error(e),
    }
}

async fn chat_block(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let conversation_id = path.into_inner();

    let chat = ChatService::new(cache.get_ref().clone());
    let other_id = match chat.get_participant_row(&pools, conversation_id, caller_id).await {
        Ok(_) => {
            match sqlx::query_scalar::<_, Uuid>(
                "SELECT participant_id FROM conversation_participants WHERE conversation_id = $1 AND participant_id != $2 LIMIT 1",
            )
            .bind(conversation_id)
            .bind(caller_id)
            .fetch_one(pools.reader())
            .await
            {
                Ok(id) => id,
                Err(_) => return HttpResponse::NotFound().json(
                    ApiResponse::<String>::error("Conversation not found".to_string(), "chat/not-found".to_string())
                ),
            }
        }
        Err(e) => return map_chat_error(e),
    };

    match chat.chat_block(&pools, caller_id, other_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Blocked".to_string())),
        Err(e) => {
            eprintln!("ERROR: chat_block failed: {}", e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to block".to_string(), "chat/block-failed".to_string())
            )
        }
    }
}

async fn chat_unblock(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let conversation_id = path.into_inner();

    let other_id = match sqlx::query_scalar::<_, Uuid>(
        "SELECT participant_id FROM conversation_participants WHERE conversation_id = $1 AND participant_id != $2 LIMIT 1",
    )
    .bind(conversation_id)
    .bind(caller_id)
    .fetch_one(pools.reader())
    .await
    {
        Ok(id) => id,
        Err(_) => return HttpResponse::NotFound().json(
            ApiResponse::<String>::error("Conversation not found".to_string(), "chat/not-found".to_string())
        ),
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.chat_unblock(&pools, caller_id, other_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Unblocked".to_string())),
        Err(e) => {
            eprintln!("ERROR: chat_unblock failed: {}", e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to unblock".to_string(), "chat/unblock-failed".to_string())
            )
        }
    }
}

async fn create_call(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<CreateCallRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let conversation_id = path.into_inner();

    let other_id = match sqlx::query_scalar::<_, Uuid>(
        "SELECT participant_id FROM conversation_participants WHERE conversation_id = $1 AND participant_id != $2 LIMIT 1",
    )
    .bind(conversation_id)
    .bind(caller_id)
    .fetch_one(pools.reader())
    .await
    {
        Ok(id) => id,
        Err(_) => return HttpResponse::NotFound().json(
            ApiResponse::<String>::error("Conversation not found".to_string(), "chat/not-found".to_string())
        ),
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.create_call(&pools, conversation_id, caller_id, other_id, body.call_type).await {
        Ok(call) => HttpResponse::Created().json(ApiResponse::success(call)),
        Err(e) => map_chat_error(e),
    }
}

async fn get_call_turn_credentials(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.issue_turn_credentials(&pools, path.into_inner(), caller_id).await {
        Ok(creds) => HttpResponse::Ok().json(ApiResponse::success(creds)),
        Err(e) => map_chat_error(e),
    }
}

#[derive(serde::Serialize)]
struct PendingCallSignalResponse {
    frame: Option<String>,
}

async fn get_pending_call_signal(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.pending_call_signal_for(&pools, path.into_inner(), caller_id).await {
        Ok(frame) => HttpResponse::Ok().json(ApiResponse::success(PendingCallSignalResponse { frame })),
        Err(e) => map_chat_error(e),
    }
}

async fn call_heartbeat(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.record_call_heartbeat(&pools, path.into_inner(), caller_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("ok".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn mark_delivered_route(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<(Uuid, Uuid)>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let (_conversation_id, message_id) = path.into_inner();

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.mark_delivered(&pools, message_id, caller_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("ok".to_string())),
        Err(e) => {
            eprintln!("ERROR: mark_delivered_route failed for message {}: {}", message_id, e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to mark delivered".to_string(), "chat/mark-delivered-failed".to_string())
            )
        }
    }
}

async fn mark_delivered_push_ack_route(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: PushAckClaims,
    path: web::Path<(Uuid, Uuid)>,
) -> impl Responder {
    let (_conversation_id, message_id) = path.into_inner();

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.mark_delivered(&pools, message_id, claims.user_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("ok".to_string())),
        Err(e) => {
            eprintln!("ERROR: mark_delivered_push_ack_route failed for message {}: {}", message_id, e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to mark delivered".to_string(), "chat/mark-delivered-failed".to_string())
            )
        }
    }
}

#[derive(serde::Deserialize)]
struct E2eePushQuery {
    device_id: Uuid,
}

async fn e2ee_push_ciphertext_route(
    pools: web::Data<DbPools>,
    claims: PushAckClaims,
    path: web::Path<(Uuid, Uuid)>,
    query: web::Query<E2eePushQuery>,
) -> impl Responder {
    let (conversation_id, message_id) = path.into_inner();
    match e2ee::push_ciphertext(&pools, conversation_id, message_id, claims.user_id, query.device_id).await {
        Ok(Some(v)) => HttpResponse::Ok().json(ApiResponse::success(v)),
        Ok(None) => HttpResponse::NotFound().json(
            ApiResponse::<String>::error("Not found".to_string(), "e2ee/not-found".to_string())
        ),
        Err(e) => map_e2ee_error(e),
    }
}

async fn get_presence(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let conversation_id = path.into_inner();

    let chat = ChatService::new(cache.get_ref().clone());
    let other_id = match chat.other_participant(&pools, conversation_id, caller_id).await {
        Ok(id) => id,
        Err(_) => return HttpResponse::NotFound().json(
            ApiResponse::<String>::error("Conversation not found".to_string(), "chat/not-found".to_string())
        ),
    };

    match chat.presence_for(&pools, caller_id, other_id).await {
        Ok(presence) => HttpResponse::Ok().json(ApiResponse::success(presence)),
        Err(e) => {
            eprintln!("ERROR: get_presence failed: {}", e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to fetch presence".to_string(), "chat/presence-failed".to_string())
            )
        }
    }
}

pub(crate) async fn get_chat_settings(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
) -> impl Responder {
    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_chat_settings(&pools, claims.user_id).await {
        Ok(settings) => HttpResponse::Ok().json(ApiResponse::success(settings)),
        Err(e) => {
            eprintln!("ERROR: get_chat_settings failed for {}: {}", claims.user_id, e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to fetch chat settings".to_string(), "chat/settings-failed".to_string())
            )
        }
    }
}

pub(crate) async fn update_chat_settings(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    body: web::Json<UpdateChatSettingsRequest>,
) -> impl Responder {
    let chat = ChatService::new(cache.get_ref().clone());
    match chat.update_chat_settings(&pools, claims.user_id, body.into_inner()).await {
        Ok(settings) => HttpResponse::Ok().json(ApiResponse::success(settings)),
        Err(e) => {
            eprintln!("ERROR: update_chat_settings failed for {}: {}", claims.user_id, e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to update chat settings".to_string(), "chat/settings-update-failed".to_string())
            )
        }
    }
}

async fn update_call_status(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<UpdateCallStatusRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.update_call_status_and_notify(&pools, path.into_inner(), body.status, caller_id).await {
        Ok(call) => HttpResponse::Ok().json(ApiResponse::success(call)),
        Err(ChatError::NotParticipant) => HttpResponse::Forbidden().json(
            ApiResponse::<String>::error("Not a participant in this call".to_string(), "chat/not-participant".to_string())
        ),
        Err(ChatError::Db(sqlx::Error::RowNotFound)) => HttpResponse::NotFound().json(
            ApiResponse::<String>::error("Call not found".to_string(), "chat/call-not-found".to_string())
        ),
        Err(e) => {
            eprintln!("ERROR: update_call_status failed: {:?}", e);
            HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to update call".to_string(), "chat/call-update-failed".to_string())
            )
        }
    }
}

async fn create_group(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    body: web::Json<CreateGroupRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.create_group_with_invite(&pools, caller_id, body.into_inner()).await {
        Ok((conversation, invite_link)) => HttpResponse::Ok().json(ApiResponse::success(
            GroupConversationResponse { conversation, invite_link },
        )),
        Err(e) => map_chat_error(e),
    }
}

async fn get_group_details(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_group_details(&pools, path.into_inner(), caller_id).await {
        Ok(details) => HttpResponse::Ok().json(ApiResponse::success(details)),
        Err(e) => map_chat_error(e),
    }
}

async fn update_group(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<UpdateGroupRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.update_group(&pools, path.into_inner(), caller_id, body.into_inner()).await {
        Ok(conversation) => HttpResponse::Ok().json(ApiResponse::success(
            GroupConversationResponse { conversation, invite_link: None },
        )),
        Err(e) => map_chat_error(e),
    }
}

async fn add_group_members(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<AddGroupMembersRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.add_group_members(&pools, path.into_inner(), caller_id, body.into_inner()).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Members added".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn remove_group_member(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<(Uuid, Uuid)>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let (conversation_id, target_id) = path.into_inner();
    let chat = ChatService::new(cache.get_ref().clone());
    match chat.remove_group_member(&pools, conversation_id, caller_id, target_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Member removed".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn leave_group(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.leave_group(&pools, path.into_inner(), caller_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Left group".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn promote_group_creator(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<PromoteGroupCreatorRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.promote_to_creator(&pools, path.into_inner(), caller_id, body.user_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Creator promoted".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn delete_group(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.delete_group(&pools, path.into_inner(), caller_id).await {
        Ok(_) => HttpResponse::Ok().json(ApiResponse::success("Group deleted".to_string())),
        Err(e) => map_chat_error(e),
    }
}

async fn get_group_suggestions(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_group_suggestions(&pools, caller_id).await {
        Ok(suggestions) => HttpResponse::Ok()
            .insert_header(("Cache-Control", "no-store"))
            .json(ApiResponse::success(suggestions)),
        Err(e) => map_chat_error(e),
    }
}

async fn set_group_invite_link(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<SetInviteLinkRequest>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.set_invite_link_enabled(&pools, path.into_inner(), caller_id, body.enabled).await {
        Ok(link) => HttpResponse::Ok().json(ApiResponse::success(link)),
        Err(e) => map_chat_error(e),
    }
}

async fn get_group_invite_preview(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<String>,
) -> impl Responder {
    let (caller_id, _) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.get_invite_preview(&pools, &path.into_inner(), caller_id).await {
        Ok(preview) => HttpResponse::Ok()
            .insert_header(("Cache-Control", "no-store"))
            .json(ApiResponse::success(preview)),
        Err(e) => map_chat_error(e),
    }
}

async fn join_group_via_invite(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    body: web::Json<JoinGroupViaLinkRequest>,
) -> impl Responder {
    let (caller_id, caller_type) = match resolve_caller_identity(&pools, &cache, &claims).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if caller_type != ParticipantType::User {
        return HttpResponse::Forbidden().json(
            ApiResponse::<String>::error("Only people can join groups".to_string(), "chat/invalid-group-request".to_string())
        );
    }

    let chat = ChatService::new(cache.get_ref().clone());
    match chat.join_via_invite_link(&pools, &body.token, caller_id).await {
        Ok(conversation) => HttpResponse::Ok().json(ApiResponse::success(
            GroupConversationResponse { conversation, invite_link: None },
        )),
        Err(e) => map_chat_error(e),
    }
}

async fn e2ee_user_id(
    pools: &DbPools,
    cache: &web::Data<CacheService>,
    claims: &AuthClaims,
) -> Result<Uuid, HttpResponse> {
    let (id, ty) = resolve_caller_identity(pools, cache, claims).await?;
    if !matches!(ty, ParticipantType::User) {
        return Err(HttpResponse::Forbidden().json(
            ApiResponse::<String>::error("Not available for service accounts".to_string(), "e2ee/forbidden".to_string())
        ));
    }
    Ok(id)
}

async fn e2ee_register_device(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    body: web::Json<RegisterDeviceRequest>,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    match e2ee::register_device(&pools, user_id, body.into_inner()).await {
        Ok(()) => HttpResponse::Ok().json(ApiResponse::success("registered".to_string())),
        Err(e) => map_e2ee_error(e),
    }
}

async fn e2ee_list_devices(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    match e2ee::list_devices(&pools, user_id).await {
        Ok(v) => HttpResponse::Ok().json(ApiResponse::success(v)),
        Err(e) => map_e2ee_error(e),
    }
}

async fn e2ee_revoke_device(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    match e2ee::revoke_device(&pools, user_id, path.into_inner()).await {
        Ok(()) => HttpResponse::Ok().json(ApiResponse::success("revoked".to_string())),
        Err(e) => map_e2ee_error(e),
    }
}

async fn e2ee_prekey_counts(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    match e2ee::prekey_counts(&pools, user_id, path.into_inner()).await {
        Ok(v) => HttpResponse::Ok().json(ApiResponse::success(v)),
        Err(e) => map_e2ee_error(e),
    }
}

async fn e2ee_upload_prekeys(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<UploadPreKeysRequest>,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    match e2ee::upload_prekeys(&pools, user_id, path.into_inner(), body.into_inner()).await {
        Ok(v) => HttpResponse::Ok().json(ApiResponse::success(v)),
        Err(e) => map_e2ee_error(e),
    }
}

async fn e2ee_rotate_signed_prekey(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
    body: web::Json<RotateSignedPreKeyRequest>,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    match e2ee::rotate_signed_prekey(&pools, user_id, path.into_inner(), body.into_inner()).await {
        Ok(()) => HttpResponse::Ok().json(ApiResponse::success("rotated".to_string())),
        Err(e) => map_e2ee_error(e),
    }
}

async fn e2ee_prekey_bundles(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    body: web::Json<PreKeyBundlesRequest>,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    match e2ee::prekey_bundles(&pools, user_id, body.into_inner()).await {
        Ok(v) => HttpResponse::Ok().json(ApiResponse::success(v)),
        Err(e) => map_e2ee_error(e),
    }
}

async fn e2ee_conversation_devices(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    match e2ee::conversation_devices(&pools, path.into_inner(), user_id).await {
        Ok(v) => HttpResponse::Ok().json(ApiResponse::success(v)),
        Err(e) => map_e2ee_error(e),
    }
}

async fn e2ee_enable_conversation(
    pools: web::Data<DbPools>,
    cache: web::Data<CacheService>,
    claims: AuthClaims,
    path: web::Path<Uuid>,
) -> impl Responder {
    let user_id = match e2ee_user_id(&pools, &cache, &claims).await { Ok(v) => v, Err(r) => return r };
    let conversation_id = path.into_inner();
    match e2ee::enable_conversation(&pools, conversation_id, user_id).await {
        Ok(state) => {
            if let Ok(members) = e2ee::member_user_ids(&pools, conversation_id).await {
                let payload = serde_json::json!({
                    "type": "e2ee_enabled",
                    "conversation_id": conversation_id,
                    "enabled_at": state.enabled_at,
                    "enabled_by": state.enabled_by,
                })
                .to_string();
                for m in members {
                    if let Err(err) = cache.publish_user_event(&m.to_string(), &payload).await {
                        log::error!("e2ee_enable: failed to notify {}: {}", m, err);
                    }
                }
            }
            HttpResponse::Ok().json(ApiResponse::success(state))
        }
        Err(e) => map_e2ee_error(e),
    }
}
