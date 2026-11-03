import Foundation

public enum AppRelaunchScript {
    /// App path is $0 and the original PID is $1; neither is interpolated into shell code.
    /// A timed-out wait must not activate the old application instead of relaunching it.
    public static let contents = """
        attempts=0
        while kill -0 "$1" 2>/dev/null; do
            if [ "$attempts" -ge 50 ]; then exit 1; fi
            sleep 0.2
            attempts=$((attempts + 1))
        done
        /usr/bin/open "$0"
        """
}
