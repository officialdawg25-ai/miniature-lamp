-- Nine read policies were named "institutional" but their condition was a bare true, so any signed-in user (not only the approved
-- institutional allowlist) could read them. Replace the condition with the allowlist check used everywhere else in the schema.
-- Only one user exists today and that user is on the allowlist, so no current access is lost.
alter policy core_currencies_institutional_authenticated on core.currencies using ((select private.is_institutional_user()));
alter policy core_data_sources_institutional_authenticated on core.data_sources using ((select private.is_institutional_user()));
alter policy core_instruments_institutional_authenticated on core.instruments using ((select private.is_institutional_user()));
alter policy ml_feature_definitions_institutional_authenticated on ml.feature_definitions using ((select private.is_institutional_user()));
alter policy ml_feature_values_institutional_authenticated on ml.feature_values using ((select private.is_institutional_user()));
alter policy ml_model_versions_institutional_authenticated on ml.model_versions using ((select private.is_institutional_user()));
alter policy ml_predictions_institutional_authenticated on ml.predictions using ((select private.is_institutional_user()));
alter policy research_backtest_runs_institutional_authenticated on research.backtest_runs using ((select private.is_institutional_user()));
alter policy research_backtest_trades_institutional_authenticated on research.backtest_trades using ((select private.is_institutional_user()));
