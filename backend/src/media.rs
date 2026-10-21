// SPDX-License-Identifier: AGPL-3.0

use actix_web::{web, HttpResponse, Responder};
use aws_sdk_s3::presigning::PresigningConfig;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use uuid::Uuid;

use crate::auth::AuthClaims;
use crate::models::ApiResponse;

pub fn configure(cfg: &mut web::ServiceConfig) {
    cfg.route("/media/presign", web::post().to(presign));
}

use std::sync::OnceLock;

static BUCKET_CELL: OnceLock<String> = OnceLock::new();
static CDN_DOMAIN_CELL: OnceLock<String> = OnceLock::new();

fn bucket() -> &'static str {
    BUCKET_CELL.get_or_init(|| {
        std::env::var("MEDIA_BUCKET").expect("MEDIA_BUCKET env var must be set")
    })
}

fn cdn_domain() -> &'static str {
    CDN_DOMAIN_CELL.get_or_init(|| {
        std::env::var("MEDIA_CDN_DOMAIN").expect("MEDIA_CDN_DOMAIN env var must be set")
    })
}

const PRESIGN_TTL: Duration = Duration::from_secs(15 * 60);

#[derive(Debug, Deserialize, Serialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
pub enum MediaCategory {
    ChatBit,
    ChatBitThumbnail,
    ChatVoice,
    ChatFile,
    ChatMedia,
    ChatEncrypted,
}

impl MediaCategory {
    fn key_prefix(self) -> &'static str {
        match self {
            MediaCategory::ChatBit => "chat/bits",
            MediaCategory::ChatBitThumbnail => "chat/bit-thumbnails",
            MediaCategory::ChatVoice => "chat/voice",
            MediaCategory::ChatFile => "chat/files",
            MediaCategory::ChatMedia => "chat/media",
            MediaCategory::ChatEncrypted => "chat/e2ee",
        }
    }

    fn allowed_extensions(self) -> &'static [&'static str] {
        match self {
            MediaCategory::ChatBit | MediaCategory::ChatBitThumbnail => &["jpg", "jpeg", "png", "mov", "mp4"],
            MediaCategory::ChatVoice => &["m4a", "caf"],
            MediaCategory::ChatFile => &["pdf", "doc", "docx", "txt", "zip", "csv", "xlsx"],
            MediaCategory::ChatMedia => &["jpg", "jpeg", "png", "mov", "mp4"],
            MediaCategory::ChatEncrypted => &["bin"],
        }
    }

    fn max_size_bytes(self) -> i64 {
        match self {
            MediaCategory::ChatBit => 50 * 1024 * 1024,
            MediaCategory::ChatBitThumbnail => 2 * 1024 * 1024,
            MediaCategory::ChatVoice => 10 * 1024 * 1024,
            MediaCategory::ChatFile => 100 * 1024 * 1024,
            MediaCategory::ChatMedia => 50 * 1024 * 1024,
            MediaCategory::ChatEncrypted => 101 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct PresignRequest {
    pub category: MediaCategory,
    pub file_extension: String,
    pub content_type: String,
}

#[derive(Debug, Serialize)]
pub struct PresignResponse {
    pub upload_url: String,
    pub public_url: String,
    pub key: String,
    pub expires_in_seconds: u64,
    pub required_content_type: String,
}

async fn presign(claims: AuthClaims, body: web::Json<PresignRequest>) -> impl Responder {
    let ext = body.file_extension.trim_start_matches('.').to_lowercase();
    if !body.category.allowed_extensions().contains(&ext.as_str()) {
        return HttpResponse::BadRequest().json(
            ApiResponse::<String>::error(
                format!("Extension '{}' not allowed for this media category", ext),
                "media/invalid-extension".to_string(),
            ),
        );
    }

    if matches!(body.category, MediaCategory::ChatEncrypted) && body.content_type != "application/octet-stream" {
        return HttpResponse::BadRequest().json(ApiResponse::<String>::error(
            "Encrypted uploads must be application/octet-stream".to_string(),
            "media/invalid-content-type".to_string(),
        ));
    }

    let key = format!("{}/{}/{}.{}", body.category.key_prefix(), claims.user_id, Uuid::new_v4(), ext);

    let config = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    let client = aws_sdk_s3::Client::new(&config);

    let presigned = match client
        .put_object()
        .bucket(bucket())
        .key(&key)
        .content_type(&body.content_type)
        .presigned(match PresigningConfig::expires_in(PRESIGN_TTL) {
            Ok(cfg) => cfg,
            Err(e) => {
                eprintln!("ERROR: presign config failed: {}", e);
                return HttpResponse::InternalServerError().json(
                    ApiResponse::<String>::error("Failed to prepare upload".to_string(), "media/presign-config-failed".to_string()),
                );
            }
        })
        .await
    {
        Ok(p) => p,
        Err(e) => {
            eprintln!("ERROR: S3 presign failed: {}", e);
            return HttpResponse::InternalServerError().json(
                ApiResponse::<String>::error("Failed to prepare upload".to_string(), "media/presign-failed".to_string()),
            );
        }
    };

    HttpResponse::Ok().json(ApiResponse::success(PresignResponse {
        upload_url: presigned.uri().to_string(),
        public_url: format!("{}/{}", cdn_domain(), key),
        key,
        expires_in_seconds: PRESIGN_TTL.as_secs(),
        required_content_type: body.content_type.clone(),
    }))
}
