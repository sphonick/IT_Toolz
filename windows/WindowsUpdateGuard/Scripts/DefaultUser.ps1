$scripts = @(
	{
		reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f;
	};
	{
		Remove-ItemProperty -LiteralPath 'Registry::HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup' -Force -ErrorAction 'Continue';
	};
	{
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f;
	};
	{
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Edge\SmartScreenEnabled" /ve /t REG_DWORD /d 0 /f;
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Edge\SmartScreenPuaEnabled" /ve /t REG_DWORD /d 0 /f;
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\AppHost" /v EnableWebContentEvaluation /t REG_DWORD /d 0 /f;
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\AppHost" /v PreventOverride /t REG_DWORD /d 0 /f;
	};
	{
		$names = @(
		  'ContentDeliveryAllowed';
		  'FeatureManagementEnabled';
		  'OEMPreInstalledAppsEnabled';
		  'PreInstalledAppsEnabled';
		  'PreInstalledAppsEverEnabled';
		  'SilentInstalledAppsEnabled';
		  'SoftLandingEnabled';
		  'SubscribedContentEnabled';
		  'SubscribedContent-310093Enabled';
		  'SubscribedContent-338387Enabled';
		  'SubscribedContent-338388Enabled';
		  'SubscribedContent-338389Enabled';
		  'SubscribedContent-338393Enabled';
		  'SubscribedContent-353698Enabled';
		  'SystemPaneSuggestionsEnabled';
		);
		
		foreach( $name in $names ) {
		  reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v $name /t REG_DWORD /d 0 /f;
		}
	};
	{
		reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle Normal -NoProfile -Command \""Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UserOnce.ps1' -Raw | Invoke-Expression;\""" /f;
	};
);

& {
	[float] $complete = 0;
	[float] $increment = 100 / $scripts.Count;
	foreach( $script in $scripts ) {
		Write-Progress -Activity 'Running scripts to modify the default user’’s registry hive. Do not close this window.' -PercentComplete $complete;
		& $script;
		$complete += $increment;
	}
} *>&1 >> "C:\Windows\Setup\Scripts\DefaultUser.log";