# DPN Keycloak User Guide

> **Audience:** Administrator of Operations team to manage (create/update/delete) users for DPN UI interfaces.

---

## Table of Contents

1. [What is the DPN Keycloak?](#1-what-is-the-dpn-keycloak)
2. [Accessing the Portal](#2-accessing-the-portal)
3. [User Management in DPN Keycloak](#3-user-management-in-dpn-keycloak)
4. [Audit Events](#4-audit-events)

---

## 1. What is the DPN Keycloak?

The DPN Keycloak is an user interface which is used to manage users for accessing DPN UI components which are part of DPN Portal. The access to this DPN Keycloak UI is restricted to only administrator. The administrator will be able to following task in Keycloak UI
a) create new user
b) assign (unassign) user to(from) role
c) assign (unassign) user to(from) group
d) delete user


## 2. Accessing the Portal
The portal can be accessed via keycloak admin or dpnadmin role
For keycloak admin role use below url
```text
https://dpn-keycloak-service-lb.<namespace>.svc.cluster.local:<portal-port>
```
For dpnadmin role use below url
```text
https://dpn-keycloak-service-lb.<namespace>.svc.cluster.local:<portal-port>/admin/dpn-realm/console/
```

![Keycloak login page](images/09_keycloak_login_page.jpg)



a) After login using keycloak admin role user administrator lands at default landing page
   ![Keycloak landing page](images/09_keycloak_landing_page.png)
b) Keycloak admin can manage all the realms from Manage realms 
   ![Manage realms](images/09_keycloak_manage_realms.png)
c) If logged in using dpnadmin user (which is specifically pre-configured for dpn UI components) user lands at
   ![DPN realm landing page](images/09_keycloak_dpn_realm_landing_page.png)
d) Click on Realm roles to see available pre-configured roles for dpn
   ![DPN realm roles](images/09_keycloak_dpn_realm_roles.png)
Note that dpnadmin, dpnreader and dpnaperator roles are pre-configured for dpn. Rest of them are default or custom roles.

## 3. User Management in DPN Keycloak

To manage users for dpn-realm use dpnadmin role user.
The user management activities involve user creation, user setting modification, user deletion.
a) User Creation: 
    i. Click on on Users on left panel
    ![Users management page](images/09_keycloak_user_management_page.png)
    ii. Click on Add user and fill out the required details in the respective fields (username, email, first name, last name). Mark email verfied as on. Then click on Create.
    ![Create user - step 1](images/09_keycloak_user_creation_step1_dpnadminuser2.png)
    iii. Move to Credential tab. Click on Set password
    ![Create user - step 3](images/09_keycloak_user_creation_step3_dpnadminuser2.png)
    iv. Set password and mark Temporary as off and then save it
    ![Create user - step 4](images/09_keycloak_user_creation_step4_dpnadminuser2.png)
    v. Move to Role Mapping. This is where user is attached to a role. Click on Assign Role and choose Realm roles from dropdown.
    ![Create user - step 5](images/09_keycloak_user_creation_step5_dpnadminuser2.png)
    vi. Select dpnadmin , dpnreader or dpnoperator as the role. If the user is expected to perform read/write activities then choose dpnadmin as role. If user is expected to have view ability then choose dpnreader as role. If user is expected only to manage dpn pipeline orchestration then choose dpnoperator role
    ![Create user - step 6](images/09_keycloak_user_creation_step6_dpnadminuser2.png)
    vii. Move to group allocation. This is where user is made part of any of the already created groups. For dpnadmin role users select dpn-admins or select dpn-readers for dpnreader role users or select dpn-operators for dpnoperator role users
    ![Create user - step 7](images/09_keycloak_user_creation_step7_dpnadminuser2.png)
    Once above steps are performed then save it.Following the above steps the administrator of DPN Keycloak create a new user, sets credential , assign to a role and its corresponding group.
    Upon creation of user the user now becomes available to use for DPN UI portals.

b) User modification:
    i. Choose any user which are already created.
    ii. Edit its settings. Administrator can assign/unassign the user to any new role or group. 

c) User Deletion:
    i. Choose any user which are already created. Select it and click on delete.
    ![User deletion](images/09_keycloak_user_deletion.png)


## 4. Audit Events

All the activities using any of the users which are created in DPN Keycloak are tracked and persisted. The past activities
of users are available under Events section. Administrator can choose to go through non-admin user events
or admin user events.
![Audit events](images/09_keycloak_audit_events_01.png)
By clicking on any particular event it provides detailed information about that particular event.
![Audit event detail](images/09_keycloak_audit_events_02.png)
