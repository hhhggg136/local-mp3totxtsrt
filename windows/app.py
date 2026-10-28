if __name__ == '__main__':
    import sys
    if len(sys.argv)>1 and sys.argv[1]=='--self-test':
        from tingting.selftest import main
        main(sys.argv[2])
    else:
        from tingting.gui import main
        main()
