auto members = app.group("/api/v1"); // the routes that know who calls (adapters/http/auth.d)
members.use(devAuth());
members.mount(construct!CompanyController(a));
