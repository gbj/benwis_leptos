pub mod auth;
pub mod todo;
pub mod user;
pub mod dark_mode;

use cfg_if::cfg_if;

cfg_if! {
    if #[cfg(feature = "ssr")] {
        use sqlx::SqlitePool;
        use leptos::*;
        use crate::functions::auth::AuthSession;

        pub fn pool(cx: Scope) -> Result<SqlitePool, ServerFnError> {
            Ok(use_context::<SqlitePool>(cx)
                .ok_or("Pool missing.")
                .map_err(|e| ServerFnError::ServerError(e.to_string()))?)
        }
    
        pub fn auth(cx: Scope) -> Result<AuthSession, ServerFnError> {
            Ok(use_context::<AuthSession>(cx)
                .ok_or("Auth session missing.")
                .map_err(|e| ServerFnError::ServerError(e.to_string()))?)
        }
        pub fn register_server_functions() {
            _ = todo::GetTodos::register();
            _ = todo::AddTodo::register();
            _ = todo::DeleteTodo::register();
            _ = auth::Login::register();
            _ = auth::Logout::register();
            _ = auth::Signup::register();
            _ = user::GetUser::register();
            _ = dark_mode::ToggleDarkMode::register();
        }
}}