$scripts = @(
	{
		cmd.exe /c "rmdir C:\Windows.old";
	};
);

& {
	[float] $complete = 0;
	[float] $increment = 100 / $scripts.Count;
	foreach( $script in $scripts ) {
		Write-Progress -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
		& $script;
		$complete += $increment;
	}
} *>&1 >> "C:\Windows\Setup\Scripts\FirstLogon.log";