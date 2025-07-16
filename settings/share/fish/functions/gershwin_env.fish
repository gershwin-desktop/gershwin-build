function gershwin_env
  /bin/sh -c '. /System/Library/Makefiles/GNUstep.sh; env' | while read -l line
    set -l parts (string split -m1 "=" $line)
    if test (count $parts) -eq 2
      set -l var $parts[1]
      set -l val $parts[2]
      switch $var
        case PWD SHLVL _
          # skip read-only or undesired vars
        case '*'
          set -gx $var $val
      end
    end
  end
end
