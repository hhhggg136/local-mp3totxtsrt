if __name__ == '__main__':
    import sys
    if len(sys.argv)>1 and sys.argv[1]=='--component-status':
        import json
        from pathlib import Path
        from tingting.media import Runtime
        from tingting.components import Components
        runtime=Runtime()
        try:
            manager=Components(runtime)
            Path(sys.argv[2]).write_text(json.dumps({n:manager.ready(n) for n in manager.catalog['components']}),encoding='utf-8')
        finally:runtime.close()
    elif len(sys.argv)>1 and sys.argv[1]=='--configure-components':
        import json
        from pathlib import Path
        from tingting.media import Runtime
        from tingting.components import Components
        runtime=Runtime()
        try:
            manager=Components(runtime)
            for name,item in manager.catalog['components'].items():
                manager.install(name,Path(sys.argv[2])/item['url'].rsplit('/',1)[-1])
        finally:runtime.close()
    elif len(sys.argv)>1 and sys.argv[1]=='--self-test':
        from tingting.selftest import main
        main(sys.argv[2])
    else:
        from tingting.gui import main
        main()
