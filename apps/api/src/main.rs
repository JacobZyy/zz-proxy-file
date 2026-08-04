mod validation;

use std::{env, error::Error};

use axum::{
    Json, Router,
    extract::{Path, State, rejection::JsonRejection},
    http::{HeaderMap, HeaderValue, Method, StatusCode, header::CONTENT_TYPE},
    response::{IntoResponse, Response},
    routing::get,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{FromRow, PgPool, postgres::PgPoolOptions};
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing::error;
use tracing_subscriber::EnvFilter;

const DEFAULT_CONFIG: &str = include_str!("../../../clash.yaml");
const DEFAULT_DATABASE_URL: &str = "postgres://postgres:postgres@localhost:54329/zz_proxy_file";
const DEFAULT_BIND_ADDR: &str = "127.0.0.1:3001";
const DEFAULT_CORS_ORIGIN: &str = "http://127.0.0.1:5173";
const DEFAULT_CONFIG_SEED: &str = "default-clash-config-v1";
const API_PREFIX: &str = "/clash-config-tool";

#[derive(Clone)]
struct AppState {
    pool: PgPool,
}

#[derive(FromRow)]
struct ConfigRow {
    id: i64,
    name: String,
    slug: String,
    document: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfigRecord {
    id: i64,
    name: String,
    slug: String,
    document: Value,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct UpsertConfig {
    name: String,
    slug: String,
    document: Value,
}

enum AppError {
    BadRequest(String),
    NotFound,
    Conflict(String),
    Database(sqlx::Error),
    Internal(String),
}

impl From<sqlx::Error> for AppError {
    fn from(error: sqlx::Error) -> Self {
        if error
            .as_database_error()
            .is_some_and(|database_error| database_error.is_unique_violation())
        {
            return Self::Conflict("slug already exists".to_owned());
        }
        Self::Database(error)
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, message),
            Self::NotFound => (StatusCode::NOT_FOUND, "configuration not found".to_owned()),
            Self::Conflict(message) => (StatusCode::CONFLICT, message),
            Self::Database(database_error) => {
                error!(error = %database_error, "database request failed");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "database request failed".to_owned(),
                )
            }
            Self::Internal(message) => {
                error!(error = %message, "internal request failure");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal request failure".to_owned(),
                )
            }
        };
        (status, Json(json!({ "error": message }))).into_response()
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    validation::parse_and_validate(DEFAULT_CONFIG).map_err(std::io::Error::other)?;
    let database_url = env::var("DATABASE_URL").unwrap_or_else(|_| DEFAULT_DATABASE_URL.to_owned());
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await?;
    sqlx::migrate!().run(&pool).await?;
    seed_default_config(&pool).await?;

    let cors_origin = env::var("CORS_ORIGIN").unwrap_or_else(|_| DEFAULT_CORS_ORIGIN.to_owned());
    let app = app(AppState { pool }, cors_origin.parse()?);
    let bind_addr = env::var("BIND_ADDR").unwrap_or_else(|_| DEFAULT_BIND_ADDR.to_owned());
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    tracing::info!(address = %bind_addr, "API listening");
    axum::serve(listener, app).await?;
    Ok(())
}

fn app(state: AppState, cors_origin: HeaderValue) -> Router {
    let prefixed_routes = Router::new()
        .route("/health", get(health))
        .route("/api/configs", get(list_configs).post(create_config))
        .route(
            "/api/configs/{id}",
            get(get_config).put(update_config).delete(delete_config),
        )
        .route("/subscriptions/{slug}", get(subscription));

    Router::new()
        .nest(API_PREFIX, prefixed_routes)
        .fallback(not_found)
        .method_not_allowed_fallback(method_not_allowed)
        .layer(TraceLayer::new_for_http())
        .layer(
            CorsLayer::new()
                .allow_origin(cors_origin)
                .allow_methods([Method::GET, Method::POST, Method::PUT, Method::DELETE])
                .allow_headers([CONTENT_TYPE]),
        )
        .with_state(state)
}

async fn seed_default_config(pool: &PgPool) -> Result<(), sqlx::Error> {
    let mut transaction = pool.begin().await?;
    let inserted = sqlx::query(
        "INSERT INTO seed_history (seed_key) VALUES ($1) ON CONFLICT (seed_key) DO NOTHING",
    )
    .bind(DEFAULT_CONFIG_SEED)
    .execute(&mut *transaction)
    .await?
    .rows_affected();

    if inserted == 1 {
        sqlx::query(
            "INSERT INTO configurations (name, slug, document) VALUES ($1, $2, $3) \
             ON CONFLICT (slug) DO NOTHING",
        )
        .bind("Zhuanzhuan")
        .bind("zhuanzhuan")
        .bind(DEFAULT_CONFIG)
        .execute(&mut *transaction)
        .await?;
    }

    transaction.commit().await
}

async fn health() -> Json<Value> {
    Json(json!({ "status": "ok" }))
}

async fn list_configs(State(state): State<AppState>) -> Result<Json<Vec<ConfigRecord>>, AppError> {
    let rows = sqlx::query_as::<_, ConfigRow>(
        "SELECT id, name, slug, document, created_at, updated_at \
         FROM configurations ORDER BY created_at DESC, id DESC",
    )
    .fetch_all(&state.pool)
    .await?;
    rows.into_iter()
        .map(config_record)
        .collect::<Result<Vec<_>, _>>()
        .map(Json)
}

async fn get_config(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<ConfigRecord>, AppError> {
    let id = parse_id(&id)?;
    let row = find_config(&state.pool, id).await?;
    Ok(Json(config_record(row)?))
}

async fn create_config(
    State(state): State<AppState>,
    payload: Result<Json<UpsertConfig>, JsonRejection>,
) -> Result<(StatusCode, Json<ConfigRecord>), AppError> {
    let payload = json_payload(payload)?;
    let yaml = validated_yaml(&payload)?;
    let row = sqlx::query_as::<_, ConfigRow>(
        "INSERT INTO configurations (name, slug, document) VALUES ($1, $2, $3) \
         RETURNING id, name, slug, document, created_at, updated_at",
    )
    .bind(payload.name.trim())
    .bind(payload.slug.trim())
    .bind(yaml)
    .fetch_one(&state.pool)
    .await?;
    Ok((StatusCode::CREATED, Json(config_record(row)?)))
}

async fn update_config(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: Result<Json<UpsertConfig>, JsonRejection>,
) -> Result<Json<ConfigRecord>, AppError> {
    let id = parse_id(&id)?;
    let payload = json_payload(payload)?;
    let yaml = validated_yaml(&payload)?;
    let row = sqlx::query_as::<_, ConfigRow>(
        "UPDATE configurations SET name = $1, slug = $2, document = $3, updated_at = NOW() \
         WHERE id = $4 \
         RETURNING id, name, slug, document, created_at, updated_at",
    )
    .bind(payload.name.trim())
    .bind(payload.slug.trim())
    .bind(yaml)
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(AppError::NotFound)?;
    Ok(Json(config_record(row)?))
}

async fn delete_config(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, AppError> {
    let id = parse_id(&id)?;
    let result = sqlx::query("DELETE FROM configurations WHERE id = $1")
        .bind(id)
        .execute(&state.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn subscription(
    State(state): State<AppState>,
    Path(slug): Path<String>,
) -> Result<(HeaderMap, String), AppError> {
    let document: Option<String> =
        sqlx::query_scalar("SELECT document FROM configurations WHERE slug = $1")
            .bind(slug)
            .fetch_optional(&state.pool)
            .await?;
    let document = document.ok_or(AppError::NotFound)?;
    let mut headers = HeaderMap::new();
    headers.insert(
        CONTENT_TYPE,
        HeaderValue::from_static("text/yaml; charset=utf-8"),
    );
    Ok((headers, document))
}

async fn find_config(pool: &PgPool, id: i64) -> Result<ConfigRow, AppError> {
    sqlx::query_as::<_, ConfigRow>(
        "SELECT id, name, slug, document, created_at, updated_at \
         FROM configurations WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?
    .ok_or(AppError::NotFound)
}

fn config_record(row: ConfigRow) -> Result<ConfigRecord, AppError> {
    let document = serde_yaml::from_str(&row.document)
        .map_err(|error| AppError::Internal(format!("stored configuration {}: {error}", row.id)))?;
    Ok(ConfigRecord {
        id: row.id,
        name: row.name,
        slug: row.slug,
        document,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

fn json_payload(
    payload: Result<Json<UpsertConfig>, JsonRejection>,
) -> Result<UpsertConfig, AppError> {
    payload.map(|Json(payload)| payload).map_err(|rejection| {
        AppError::BadRequest(format!("invalid JSON: {}", rejection.body_text()))
    })
}

fn validated_yaml(payload: &UpsertConfig) -> Result<String, AppError> {
    validate_metadata(&payload.name, &payload.slug)?;
    validation::validate(&payload.document).map_err(AppError::BadRequest)?;
    serde_yaml::to_string(&payload.document).map_err(|error| {
        AppError::BadRequest(format!("document cannot be encoded as YAML: {error}"))
    })
}

fn validate_metadata(name: &str, slug: &str) -> Result<(), AppError> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 120 {
        return Err(AppError::BadRequest(
            "name must contain 1 to 120 characters".to_owned(),
        ));
    }

    let slug = slug.trim();
    let valid_slug = !slug.is_empty()
        && slug.len() <= 80
        && slug.split('-').all(|part| {
            !part.is_empty()
                && part
                    .chars()
                    .all(|character| character.is_ascii_lowercase() || character.is_ascii_digit())
        });
    if !valid_slug {
        return Err(AppError::BadRequest(
            "slug must contain 1 to 80 lowercase ASCII letters, numbers, or single hyphens"
                .to_owned(),
        ));
    }
    Ok(())
}

fn parse_id(id: &str) -> Result<i64, AppError> {
    id.parse::<i64>()
        .ok()
        .filter(|id| *id > 0)
        .ok_or_else(|| AppError::BadRequest("id must be a positive integer".to_owned()))
}

async fn not_found() -> AppError {
    AppError::NotFound
}

async fn method_not_allowed() -> impl IntoResponse {
    (
        StatusCode::METHOD_NOT_ALLOWED,
        Json(json!({ "error": "method not allowed" })),
    )
}

#[cfg(test)]
mod tests {
    use super::{parse_id, validate_metadata};

    #[test]
    fn validates_resource_identifiers() {
        assert!(parse_id("1").is_ok());
        assert!(parse_id("0").is_err());
        assert!(validate_metadata("Personal", "personal-config").is_ok());
        assert!(validate_metadata("Personal", "-personal").is_err());
        assert!(validate_metadata("Personal", "PERSONAL").is_err());
    }
}
