auto members = app.group("/api/v1"); // the routes that know who calls (adapters/http/auth.d)
members.use(devAuth());
members.mount(new CompanyController(new CreateCompany(a.uow, a.companies, a.memberships, a.clock, a.ids),
    new GetCompany(a.companies), new ListMembers(a.memberships)));
